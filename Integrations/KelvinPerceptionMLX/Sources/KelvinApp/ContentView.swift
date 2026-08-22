import SwiftUI
// @preconcurrency: this file hands CIImages to detached tasks in several places. CIImage is
// Sendable on the macOS 27 SDK and not on the one CI builds against, so those crossings are
// clean here and data-race errors there. See KelvinCore/Render/ImageWriter for the full note.
@preconcurrency import CoreImage
import CryptoKit
import UniformTypeIdentifiers
import Metal
import KelvinCore
import KelvinPerceptionMLX
import os

// MARK: - Design system: "an instrument for light"
//
// Kelvin is the unit of colour temperature — the blackbody scale from warm amber (~2700K)
// through daylight white to cool blue (~9000K). The whole identity derives from that scale,
// which is also real data (every recipe carries a temperature). Dark "darkroom" base so images
// are judged against neutral surrounds; monospaced readouts for the measured numbers; the
// signature is the temperature rail marking each look's white balance on the Kelvin scale.

enum Theme {
    static let base     = Color(hex: 0x121418)   // darkroom, cool near-black
    static let surface  = Color(hex: 0x1A1D23)
    static let surface2 = Color(hex: 0x232830)
    static let hairline = Color(hex: 0x30363F)
    static let ink      = Color(hex: 0xEDEFF3)
    static let inkDim   = Color(hex: 0x8B93A0)
    static let inkFaint = Color(hex: 0x565E6A)
    static let warm     = Color(hex: 0xFF9A55)   // ~2700K
    static let neutral  = Color(hex: 0xF1EADC)   // ~5500K
    static let cool     = Color(hex: 0x6FACFF)   // ~9000K
    static let glow     = Color(hex: 0xFF9A55)   // primary accent
    /// "Look at this" — deliberately NOT the accent colour, and not red. A soft-focus flag is a
    /// question for the photographer, not an error and not a recommendation.
    static let warn     = Color(hex: 0xE8C468)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: - Glass
    //
    // **The one rule: glass never touches the photograph.**
    //
    // Translucency is a colour cast. A material behind the canvas would pull whatever is underneath
    // it — the desktop, another window, the Dock — through the surround the eye uses as its
    // reference while judging a grade, and it would do it differently depending on what was open
    // behind Kelvin. So the canvas and its immediate surround stay flatly opaque, forever, and the
    // glass goes on the chrome that floats away from the image: the header, the panel, the footer.
    // That is not a compromise on the look; it is the difference between a darkroom and a lightbox.
    //
    // Real `Material` rather than a translucent fill, because the ask was an app that looks like
    // Apple built it and this is the actual mechanism — backdrop blur plus vibrancy, matched to the
    // system, adapting to what is behind the window.

    /// The floating-chrome material. Behind the panel and the header.
    static let glassSurface: Material = .regularMaterial
    /// Lighter, for cards sitting ON the panel — a second level of the same idea.
    static let glassCard: Material = .ultraThinMaterial

    /// **The signature.** A hairline lit along the blackbody curve — warm at one end, daylight
    /// through the middle, cool at the other — on the top edge of a floating surface.
    ///
    /// This is Kelvin's own physics used as an edge light rather than as a decoration: the same
    /// 2700K → 5500K → 9000K ramp that the temperature rail is built from, the app is named after,
    /// and the icon draws. A glass panel in any other app has a plain white rim; this one catches
    /// light the colour of the thing the product measures.
    ///
    /// Kept to a single hairline and to top edges only. It is the one loud gesture in the pass, and
    /// it earns that by being one pixel tall.
    static let rimLight = LinearGradient(
        colors: [warm.opacity(0.55), neutral.opacity(0.32), cool.opacity(0.5)],
        startPoint: .leading, endPoint: .trailing)

    /// A softer version for card edges, where a full-strength rim on every box would become noise.
    static let rimLightSoft = LinearGradient(
        colors: [warm.opacity(0.22), neutral.opacity(0.13), cool.opacity(0.2)],
        startPoint: .leading, endPoint: .trailing)
}

/// A floating chrome surface: material, a hairline rim lit along the colour-temperature curve, and
/// nothing else.
///
/// A `ViewModifier` rather than a copied stack of modifiers, so "what a floating surface looks like"
/// has one definition and the rim cannot drift out of agreement with itself across four call sites.
struct GlassSurface: ViewModifier {
    var material: Material = Theme.glassSurface
    var cornerRadius: CGFloat = 0
    var rim: LinearGradient = Theme.rimLight
    /// Where the rim sits. A panel is lit along its top; a footer sits below the photograph and is
    /// lit along the edge that faces it.
    var edge: VerticalAlignment = .top

    func body(content: Content) -> some View {
        content
            .background(material)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                Rectangle().fill(rim).frame(height: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension View {
    func glassSurface(material: Material = Theme.glassSurface,
                      cornerRadius: CGFloat = 0,
                      rim: LinearGradient = Theme.rimLight,
                      edge: VerticalAlignment = .top) -> some View {
        modifier(GlassSurface(material: material, cornerRadius: cornerRadius, rim: rim, edge: edge))
    }
}

/// Motion in a darkroom: enough to say that something changed, never enough to look at.
///
/// Two durations and one curve, so nothing in the app can ease differently from anything else,
/// and so no amount of later editing can turn this into a place where things bounce. Ease-out
/// only — a movement that decelerates into place reads as the UI settling, where anything that
/// overshoots reads as the UI performing.
///
/// Everything goes through `gated`. Reduce Motion is a photographer asking for stillness, and
/// `nil` is what both `withAnimation` and `.animation(_:value:)` take to mean "make the change
/// now, without moving".
enum Motion {
    static let quick    = Animation.easeOut(duration: 0.14)
    static let standard = Animation.easeOut(duration: 0.20)

    static func gated(_ animation: Animation, _ reduced: Bool) -> Animation? {
        reduced ? nil : animation
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// The Kelvin scale: temperature → the colour a blackbody glows at, used for the rail and the
/// per-candidate white-balance dot. Amber (warm/low K) → daylight → blue (cool/high K).
enum KelvinScale {
    static let minK = 2000.0, maxK = 10000.0
    private static let warm:    (Double, Double, Double) = (255, 154, 85)
    private static let neutral: (Double, Double, Double) = (241, 234, 220)
    private static let cool:    (Double, Double, Double) = (111, 172, 255)

    static func position(_ k: Double) -> Double {
        (min(max(k, minK), maxK) - minK) / (maxK - minK)
    }

    static func color(_ k: Double) -> Color {
        let t = min(max(k, minK), maxK)
        let (a, b, f): ((Double, Double, Double), (Double, Double, Double), Double)
        if t <= 5500 { a = warm; b = neutral; f = (t - minK) / (5500 - minK) }
        else { a = neutral; b = cool; f = (t - 5500) / (maxK - 5500) }
        return Color(.sRGB,
                     red: (a.0 + (b.0 - a.0) * f) / 255,
                     green: (a.1 + (b.1 - a.1) * f) / 255,
                     blue: (a.2 + (b.2 - a.2) * f) / 255)
    }

    static let gradient = LinearGradient(
        colors: [color(2700), color(4200), color(5500), color(7000), color(9000)],
        startPoint: .leading, endPoint: .trailing)
}

struct CandidateViewModel: Identifiable {
    let id: String
    let label: String
    let baseRecipe: Recipe
    let previewImage: NSImage
}

// MARK: - App state (pipeline logic unchanged; presentation reimagined)

@Observable
@MainActor
final class AppState {
    var imageURL: URL?
    var fullResCI: CIImage?
    var proxyCI: CIImage?
    // Subject mask at proxy resolution (for live previews) and the measured subject brightness.
    /// Proxy-resolution subject/sky bitmaps for live previews (keyed "subject"/"sky").
    @ObservationIgnored private var proxyMaskBitmaps: [String: CIImage] = [:]
    @ObservationIgnored private var subjectLuma: Double?
    /// What produced this frame's subject mask. Passed to the engine so a person lift is only
    /// applied to a mask that actually found a person — see `RecipeEngine.subjectMask`.
    @ObservationIgnored private var subjectOrigin: SubjectMask.Origin?
    @ObservationIgnored private var skyLuma: Double?
    var imageId: String = ""
    var perception: Perception?
    var candidates: [CandidateViewModel] = []
    var selectedCandidateId: String?
    /// NOT `@Published`, deliberately. It is rebuilt on every tick of every drag, and publishing it
    /// woke the whole panel a second time per tick for something no view reads: the export and the
    /// craft-fix paths take it directly, and the only view that ever wanted anything out of it was
    /// the temperature rail, which reads the same number from `edit` (the recipe's globals ARE
    /// `edit` — see `updateActiveRecipe`).
    @ObservationIgnored var activeRecipe: Recipe?
    /// A preview image and THE PHOTO IT WAS MADE FROM. The pair is the unit here, never the image
    /// on its own.
    ///
    /// Held separately, the two drift. `imageURL` is set at the top of `loadPhoto`, before the
    /// decode has produced anything, so for the whole of a decode the app believed it was showing
    /// the new photo while every pixel on screen still belonged to the old one — and press-and-hold
    /// compared against the *previous* photograph's original. The same window opens on the cached
    /// path: `restore` swaps the original in immediately and the rendered preview only catches up
    /// when the background render lands. A failed decode left the mismatch in place permanently.
    ///
    /// Carrying the URL makes the mismatch unrepresentable rather than something each of those
    /// paths has to remember to avoid: an image belonging to another photo simply reads as nil, and
    /// the compare falls back to showing nothing rather than to showing the wrong photograph.
    struct TaggedPreview {
        let url: URL
        let image: NSImage
    }
    /// THE RENDER OUTPUT LIVES SOMEWHERE THE SLIDERS CANNOT SEE IT.
    ///
    /// These two were `@Published` on `AppState`, and every finished render therefore invalidated
    /// every view observing it — which is the entire edit panel. Measured during an automated drag:
    /// two full passes over the view tree per tick and 53 slider rows rebuilt in each, when the only
    /// thing that actually changed was a preview image and a histogram.
    ///
    /// Their own object, held by reference, so writing to it notifies the preview and the histogram
    /// and nothing else. `AppState` still owns it — this is about who is woken, not about where the
    /// state belongs.
    let preview = PreviewState()
    private var original: TaggedPreview?

    /// The current edit, rendered — nil until the first render for THIS photo has landed.
    var activePreviewImage: NSImage? { preview.active.flatMap { $0.url == imageURL ? $0.image : nil } }
    /// The untouched original (proxy) of the photo now open, for the press-and-hold compare.
    var originalPreviewImage: NSImage? { original.flatMap { $0.url == imageURL ? $0.image : nil } }
    var showingOriginal = false
    /// Objective craft flags on the current edit (clipping, skin, cast) — empty when clean.
    var activeCraftIssues: [AestheticEvaluator.Issue] = []
    /// The measurement those flags came from, kept so a fix can be sized from what is on screen and
    /// so the UI can ask whether a fix has anywhere left to go (see `canFix`).
    private var lastCraftReading: CraftFix.Reading?
    /// Subject fixes that have been clicked and come back with nothing to give — the control is at
    /// its ceiling, or it cannot move this photo's metric at all. Cleared whenever the base changes
    /// (new photo, new candidate, reset), because then the question is open again.
    private var exhaustedFixes: Set<AestheticEvaluator.Issue> = []

    /// The full editable global adjustment set, held as ABSOLUTE values rather than deltas. Sliders bind
    /// straight to its fields; it starts from the chosen candidate and the user takes it from there.
    var edit = GlobalAdjustments.neutral
    /// The candidate's values as generated — the baseline manual edits are measured against (for
    /// the "carry my tweaks to the batch" and preference logging), and what Reset returns to.
    @ObservationIgnored private var editBaseline = GlobalAdjustments.neutral
    /// Manual straighten angle (degrees); auto-crops the corners. Per-photo framing.
    var straighten = 0.0
    /// What the camera recorded — body, lens, exposure, when and where.
    var capture = CaptureInfo()
    /// The creative look layered on the chosen candidate, if any (see `LookPreset`).
    var activeLookId: String?
    /// Per-colour HSL (the colour mixer): band → {h,s,l}. Empty bands are dropped.
    var hsl: [String: HSLAdjustment] = [:]
    var hslBand = "red"
    let hslBands = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]

    /// A binding to one HSL component of the currently-selected colour band.
    func hslBinding(_ kp: WritableKeyPath<HSLAdjustment, Double>) -> Binding<Double> {
        Binding(
            get: { self.hsl[self.hslBand]?[keyPath: kp] ?? 0 },
            set: { newValue in
                var a = self.hsl[self.hslBand] ?? HSLAdjustment(h: 0, s: 0, l: 0)
                a[keyPath: kp] = newValue
                if a.h == 0 && a.s == 0 && a.l == 0 { self.hsl[self.hslBand] = nil }
                else { self.hsl[self.hslBand] = a }
            })
    }
    /// Manual mask control: which auto-masks are on, and each one's strength (0…100 → opacity).
    var maskEnabled: [String: Bool] = [:]
    var maskStrength: [String: Double] = [:]
    @ObservationIgnored private var baseMasks: [Mask] = []
    /// Per-mask local adjustments the user has edited, keyed by mask id then by adjustment name.
    /// The engine proposes values (a sky mask arrives with highlights pulled down); these are the
    /// overrides on top, so an untouched mask keeps exactly what the engine chose.
    var maskAdjustments: [String: [String: Double]] = [:]
    var maskFeather: [String: Double] = [:]
    var maskTightness: [String: Double] = [:]
    var maskInvert: [String: Bool] = [:]
    var showMaskOverlay: Bool = false
    /// True while a mask's TONE slider is being dragged, which hides the overlay for the duration
    /// so the photograph is visible underneath. Set by the editors, not by the renderer.
    var isAdjustingMaskTone: Bool = false

    /// Whether the overlay is actually drawing anything — the toggle being on is not enough, since
    /// with nothing selected there is no mask to draw. The pill and the `O` key report this rather
    /// than the raw flag, so the control cannot claim to be doing something invisible.
    var isOverlayShowing: Bool { showMaskOverlay && selectedMask != nil }

    /// Presentation for every adjustment in `Mask.adjustmentKeys` — the renderer's contract, which
    /// lives in Core and is tested there. This list supplies only the label, range and unit; it
    /// must not decide WHICH adjustments exist, because that is exactly how the two mask editors
    /// drifted apart (auto masks had six, hand-drawn masks three).
    ///
    /// `assertCoversTheContract()` below checks the two agree at launch in debug builds, since the
    /// app package has no test target to check it properly.
    static let maskAdjustmentSpecs: [(key: String, label: String, range: ClosedRange<Double>, unit: String)] = [
        ("exposure_ev", "Exposure",   -3...3,      " EV"),
        // RECOVERY ONLY, and the range says so. `CIHighlightShadowAdjust`'s highlight amount is
        // documented 0…1 with 1.0 meaning "no change", so the renderer's `1.0 + highlights/100`
        // clamps for any positive value and does exactly nothing — measured at ΔE 0.0. Offering a
        // slider that is dead across half its travel is worse than offering a shorter one.
        ("highlights",  "Highlight recovery", -100...0, ""),
        ("shadows",     "Shadows",    -100...100,  ""),
        ("contrast",    "Contrast",   -100...100,  ""),
        ("saturation",  "Saturation", -100...100,  ""),
        ("vibrance",    "Vibrance",   -100...100,  "")
    ]

    /// Fails loudly in debug if the panel and the renderer disagree about which adjustments exist.
    ///
    /// The app package has no test target, so this is the only place the drift that motivated
    /// `Mask.adjustmentKeys` can be caught automatically. A missing key means a slider the
    /// renderer honours that nobody can reach; an extra one means a slider that does nothing.
    static func assertCoversTheContract() {
        assert(Set(maskAdjustmentSpecs.map(\.key)) == Set(Mask.adjustmentKeys),
               "mask panel and renderer disagree: panel has "
               + "\(Set(maskAdjustmentSpecs.map(\.key)).symmetricDifference(Set(Mask.adjustmentKeys)))"
               + " that the other does not")
    }

    /// Binding for one adjustment of one mask, falling back to the engine's own value.
    func maskAdjustmentBinding(_ maskId: String, _ key: String) -> Binding<Double> {
        Binding(
            get: {
                if let v = self.maskAdjustments[maskId]?[key] { return v }
                return self.baseMasks.first { $0.id == maskId }?.adjustments[key] ?? 0
            },
            set: { newValue in
                var all = self.maskAdjustments[maskId]
                    ?? self.baseMasks.first { $0.id == maskId }?.adjustments ?? [:]
                all[key] = newValue
                self.maskAdjustments[maskId] = all
            })
    }

    func maskFeatherBinding(_ maskId: String) -> Binding<Double> {
        Binding(get: { self.maskFeather[maskId]
                        ?? self.baseMasks.first { $0.id == maskId }?.feather ?? 0 },
                set: { self.maskFeather[maskId] = $0 })
    }

    func maskTightnessBinding(_ maskId: String) -> Binding<Double> {
        Binding(get: { self.maskTightness[maskId]
                        ?? self.baseMasks.first { $0.id == maskId }?.tightness ?? 0 },
                set: { self.maskTightness[maskId] = $0 })
    }

    func maskInvertBinding(_ maskId: String) -> Binding<Bool> {
        Binding(get: { self.maskInvert[maskId]
                        ?? self.baseMasks.first { $0.id == maskId }?.invert ?? false },
                set: { self.maskInvert[maskId] = $0 })
    }

    /// Put one mask back to exactly what the engine proposed.
    func resetMask(_ maskId: String) {
        maskAdjustments.removeValue(forKey: maskId)
        maskFeather.removeValue(forKey: maskId)
        maskTightness.removeValue(forKey: maskId)
        maskInvert.removeValue(forKey: maskId)
        onEdit()
    }
    /// Hand-added parametric gradient masks (radial / linear) — the user's own local edits.
    var userMasks: [UserMaskVM] = []

    /// Every separable subject Vision found in this photo — *this* person, *that* dog, the hillside
    /// — each with its own mask, ready to be edited on its own. Empty is a real answer (a flat
    /// landscape has no subject), not a failure.
    var subjectInstances: [SubjectInstances.Instance] = []
    /// The instance the pointer is over in the list, outlined on the canvas. A row reading
    /// "Person 2" tells you nothing about which person that is until you can see it.
    var highlightedInstanceId: String?

    /// True while the pointer is over the Repair controls, which draws a ring around every detected
    /// spot on the photograph.
    ///
    /// Dust spots are a few pixels across and the whole difficulty is that you cannot see them at
    /// preview size — so a toggle you switch on and cannot verify is a toggle you have to take on
    /// faith. Hover rather than a switch, for two reasons: it is the pattern the subject list
    /// already uses (hover a row, see which person it means), and rings over a photograph are
    /// clutter for every second you are not asking the question.
    ///
    /// Deliberately NOT a before/after: the app already has one. Hold to compare shows the frame
    /// with the spots back, which answers "what did it change". This answers "what did it find".
    var showingRepairSpots = false
    /// The transient cousin: rings shown because the pointer is over the Repair controls. Kept
    /// separate from the latched toggle above so a hover-out cannot switch off something the
    /// user deliberately switched on — which is exactly what happened when one flag served both:
    /// the rings vanished the moment the pointer moved toward the photograph to look at them.
    var hoveringRepairControls = false

    /// Instances that already have a mask, so the list can show which are in play and clicking one
    /// again selects it rather than adding a duplicate.
    var maskedInstanceIds: Set<String> {
        Set(userMasks.compactMap { $0.kind == .instance ? $0.instanceId : nil })
    }

    /// Point saved per-subject masks back at the subjects in the CURRENT detection.
    ///
    /// A sidecar outlives the detection pass that made it. Reopen the photo and Vision runs again,
    /// handing out fresh per-pass indices — so a saved mask on `person1` is a mask on nothing, and
    /// the local edit the photographer saved comes back silently inert. The mask remembers where
    /// its subject *was* instead, and that survives: match the stored box against this pass by
    /// geometry and adopt whatever id it goes by now.
    ///
    /// A subject that cannot be found again keeps its old id rather than being deleted. The mask
    /// renders as nothing, but it is still in the list with its settings intact, so a detection
    /// that misses someone once does not destroy the work — reopening after it comes back finds
    /// it again.
    private func rekeyInstanceMasks() {
        let saved = userMasks.enumerated().filter { $0.element.boundInstanceId != nil }
        guard !saved.isEmpty, !subjectInstances.isEmpty else { return }
        let references = saved.compactMap { entry -> SubjectInstances.Reference? in
            guard let id = entry.element.instanceId, let box = entry.element.instanceBox else { return nil }
            return SubjectInstances.Reference(id: id, kind: entry.element.instanceKind ?? .object,
                                              boundingBox: box)
        }
        guard !references.isEmpty else { return }

        let matched = SubjectInstances.reidentify(subjectInstances, as: references)
        for (index, mask) in saved {
            guard let oldId = mask.instanceId, let now = matched.instances[oldId] else { continue }
            userMasks[index].instanceId = now.id
            userMasks[index].instanceBox = now.boundingBox
            userMasks[index].instanceKind = now.kind
        }
    }

    /// Armed by "Click a subject on the photo". The next click on the canvas picks whatever is
    /// under it instead of panning.
    ///
    /// A MODE rather than an always-live click, deliberately. A bare click on the photograph
    /// already means pan-and-do-nothing, and silently turning it into "create a mask and give it a
    /// +0.3 exposure nudge" would make the canvas unpredictable — you would stop being able to
    /// click a picture just to look at it.
    var pickingInstance = false

    /// Pick the detected subject under a click on the canvas.
    ///
    /// The last mile of a feature that was otherwise already built: `SubjectInstances.detect`
    /// returns separately-masked instances, `addInstanceMask` turns one into an editable mask, and
    /// the mask list can already highlight one on the photo. The only thing missing was pointing at
    /// the thing itself, which is how anybody actually thinks about it — you look at the rock, not
    /// at a row labelled "Subject 2".
    ///
    /// **A miss is reported, not swallowed.** Vision finds salient objects, so plenty of a real
    /// photograph is not selectable: on `_DSC6390` it segments Haystack Rock exactly and returns
    /// neither of the smaller sea stacks. Handing back an empty mask there would be a control that
    /// appears to work and does nothing.
    func pickInstance(at loc: CGPoint, container: CGSize, pad: CGFloat = 24) {
        guard pickingInstance else { return }
        let rect = imageRect(in: container, pad: pad)
        guard rect.width > 0, rect.height > 0 else { return }
        let (nx, ny) = viewToNorm(loc, in: rect)
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return }

        guard !subjectInstances.isEmpty else {
            pickingInstance = false
            statusMessage = "Nothing separable was found in this photograph to select."
            return
        }
        guard let hit = SubjectInstances.instance(at: CGPoint(x: nx, y: ny),
                                                  in: subjectInstances) else {
            // Stay armed: a miss is usually an aim problem, and disarming would make the user
            // re-arm the tool to try the same object half an inch to the left.
            statusMessage = "Nothing detected there — \(Branding.displayName) only finds subjects that stand out. "
                + "Try the middle of the object, or use a brush mask."
            return
        }
        pickingInstance = false
        addInstanceMask(hit)
        statusMessage = "Selected \(hit.label)."
    }

    /// A click on the canvas while the heal tool is armed. `remove` is the ⌥-click path.
    ///
    /// Goes through the same `imageRect` / `viewToNorm` mapping as painting and the mask handles,
    /// so healing honours zoom, pan and straighten exactly like everything else on the canvas.
    /// The tool stays armed after a click — spot healing is a sequence of small corrections, and
    /// disarming after each one would mean re-arming for every speck.
    func healAt(_ loc: CGPoint, container: CGSize, pad: CGFloat = 24, remove: Bool = false) {
        guard healToolActive else { return }
        let rect = imageRect(in: container, pad: pad)
        guard rect.width > 0, rect.height > 0 else { return }
        let (nx, ny) = viewToNorm(loc, in: rect)
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return }

        if remove {
            if !removeHealSpot(near: CGPoint(x: nx, y: ny)) {
                statusMessage = "No patch there to remove"
            }
            return
        }
        healAt(CGPoint(x: nx, y: ny))
    }

    /// Whether the brush takes coverage away instead of adding it.
    ///
    /// A mode on the tool rather than a property of the mask, because it is the same brush either
    /// way — you paint, you hold the other mode, you paint back. It sits on `AppState` beside
    /// `brushRadius` for that reason, and it deliberately does NOT reset between strokes: erasing
    /// the spill off a mask takes several passes, and a mode that snapped back to Add after each
    /// one would make the second pass silently undo the first.
    var brushErases = false

    /// Which wand mask is waiting for its seed click, if any.
    ///
    /// Carries the mask's id rather than a bare flag, unlike `pickingInstance`: a wand click sets
    /// the seed of a PARTICULAR mask, and with two wands in the list a bare flag would drop the
    /// second one's seed onto the first.
    var seedingMaskId: UUID?

    /// Put a wand mask's seed where the photographer clicked.
    ///
    /// The counterpart to `pickInstance`, and the reason both exist: Vision returns the most salient
    /// thing and stops, so on `_DSC6390` it hands back Haystack Rock and neither of the smaller sea
    /// stacks. Those stacks have nothing to click — until this. Measured on that frame, the right-hand
    /// stack comes out cleanly and holds steady across a four-times range of tolerance.
    func seedWand(at loc: CGPoint, container: CGSize, pad: CGFloat = 24) {
        guard let mid = seedingMaskId,
              let idx = userMasks.firstIndex(where: { $0.id == mid }) else { return }
        let rect = imageRect(in: container, pad: pad)
        guard rect.width > 0, rect.height > 0 else { return }
        let (nx, ny) = viewToNorm(loc, in: rect)
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return }

        userMasks[idx].cx = nx
        userMasks[idx].cy = ny
        seedingMaskId = nil
        showMaskOverlay = true
        onEdit()
        // NAME THE RISK RATHER THAN HIDE IT. The fill is contiguous, so where the thing you clicked
        // touches something else of the same colour it will walk straight into it — measured on
        // `_DSC6390`, seeding the left sea stack leaks along the surf line into Haystack Rock at
        // every tolerance that looks reasonable. The photographer cannot know that from the slider,
        // and the coverage number cannot tell the two apart either. Only the picture can, so this
        // says where to look.
        statusMessage = "Seed set. Drag Tolerance to fit the object — if the selection jumps to "
            + "the rest of the picture, it has run into something the same colour."
    }

    /// Add (or re-select) the mask for one detected subject.
    func addInstanceMask(_ instance: SubjectInstances.Instance) {
        // Kind-checked: a SKIN mask scoped to this person is a different tool, and its existence
        // must not make the pick-list refuse to create the person's lift mask.
        if let existing = userMasks.first(where: { $0.kind == .instance && $0.instanceId == instance.id }) {
            selectedUserMaskId = existing.id
            onEdit()          // selecting is not creating — do not re-arm the overlay
            return
        }
        var m = UserMaskVM(kind: .instance)
        m.instanceId = instance.id
        m.instanceLabel = instance.label
        m.instanceBox = instance.boundingBox
        m.instanceKind = instance.kind
        // A visible starting nudge, like every other mask here: a new mask that changes nothing
        // looks broken. Up for a subject (the usual reason to isolate one is that it is too dark),
        // and gentle enough to be a starting point rather than a decision.
        m.exposure = 0.3
        userMasks.append(m)
        selectedUserMaskId = m.id
        // Shown once, on CREATION only. A mask you cannot see when it appears looks broken —
        // but re-selecting an existing one used to turn the overlay back on too, which is why it
        // felt like it could not be dismissed. Turn it off and it stays off until you make
        // another mask.
        showMaskOverlay = true
        onEdit()
    }

    func adjustBrushRadius(by delta: Double) {
        brushRadius = min(0.35, max(0.02, brushRadius + delta))
    }

    func adjustHealRadius(by delta: Double) {
        healRadius = min(0.08, max(0.003, healRadius + delta))
    }

    /// Heal at a normalised point. Returns false when the click could not become a spot, so the
    /// caller can say so rather than leaving the user wondering.
    ///
    /// Sampled from the **proxy**, which is correct and is the whole point of the coordinates being
    /// normalised: the source patch is chosen from the same picture the user is looking at, and the
    /// resulting reference re-renders at export size without another search.
    @discardableResult
    func healAt(_ normalized: CGPoint) -> Bool {
        guard let proxy = proxyCI else { return false }
        guard let spot = SpotHeal.spot(in: proxy, at: normalized, radius: healRadius) else {
            statusMessage = "Nothing to heal there — that click was outside the frame"
            return false
        }
        healSpots.append(spot)
        onDiscreteEdit()
        statusMessage = healSpots.count == 1
            ? "Healed 1 spot · ⌘Z to undo"
            : "Healed \(healSpots.count) spots · ⌘Z to undo"
        return true
    }

    /// Remove the spot nearest the click, if the click is actually on one. Used by the
    /// alt-click-to-delete path.
    ///
    /// "Nearest within its own radius" rather than nearest outright, so an alt-click on empty
    /// picture removes nothing instead of silently deleting a spot somewhere else in the frame.
    @discardableResult
    func removeHealSpot(near normalized: CGPoint) -> Bool {
        var bestIndex: Int?
        var bestDistance = Double.infinity
        for (i, s) in healSpots.enumerated() {
            let dx = s.x - normalized.x, dy = s.y - normalized.y
            let d = (dx * dx + dy * dy).squareRoot()
            // Radius is a fraction of the shorter edge while dx/dy here are fractions of each axis,
            // so this is approximate. A generous 1.5× keeps a small spot clickable.
            if d <= max(s.radius * 1.5, 0.01), d < bestDistance { bestDistance = d; bestIndex = i }
        }
        guard let i = bestIndex else { return false }
        healSpots.remove(at: i)
        onDiscreteEdit()
        statusMessage = healSpots.isEmpty ? "Removed the last heal" : "Removed 1 heal"
        return true
    }

    func clearHealSpots() {
        guard !healSpots.isEmpty else { return }
        healSpots.removeAll()
        onDiscreteEdit()
        statusMessage = "Cleared every heal"
    }

    /// Spots the user has healed, in normalised coordinates — so the same list repairs the proxy
    /// preview, the full-res export, and every frame of a batch.
    ///
    /// These are placed by clicking, not detected. The detector that used to fill this array is
    /// gone; see `SpotHeal` for the measurement that killed it.
    private(set) var healSpots: [HealSpot] = []

    /// Whether the heal tool has the canvas: a click places a spot rather than doing whatever a
    /// click normally does.
    var healToolActive = false

    /// Heal size, as a fraction of the shorter edge. Small by default because this is for touch-ups
    /// — a sensor mote, a stray hair, a bit of litter on the sand — and a too-large first click is
    /// the one that makes the tool feel destructive.
    var healRadius = 0.012

    var isProcessing = false
    var statusMessage = "Drop a photo or a folder to read the light."

    private let store: PreferenceStore
    /// GPU-backed Core Image context — the "accelerator". A Metal device + cached intermediates and
    /// fast downsampling make live slider previews render on the GPU instead of the CPU.
    private let context: CIContext = {
        // Force the high-performance GPU (matters on multi-GPU Macs), cache intermediates, and skip
        // high-quality downsampling for previews. This is PREVIEW ONLY — export renders through
        // ImageWriter's own full-precision context, so output quality is never affected.
        let opts: [CIContextOption: Any] = [
            .cacheIntermediates: true, .highQualityDownsample: false, .allowLowPower: false
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: opts)
        }
        return CIContext(options: opts)
    }()
    /// Zoom (1 = fit) and pan (view points) for inspecting the photo.
    var zoom = 1.0
    var pan = CGSize.zero
    // The real on-device VLM. An actor, so the model loads once and is reused across photos.
    private let perceptionProvider = MLXPerceptionProvider()

    /// Used when the model can't run (not yet downloaded, offline). Low confidence keeps the
    /// engine on its conservative, measurement-only path rather than committing to a scene.
    private static let conservativeRead = Perception(
        scene: .other,
        subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
        lighting: Perception.Lighting(condition: .indoorDaylight, direction: .diffuse, contrastRange: .normal),
        problems: [], intent: .natural, confidence: 0.3)

    /// True while a text field is taking keystrokes, so the single-key shortcuts can get out of the
    /// way — see the shortcut block in `ContentView`.
    private(set) var isEditingText = false

    init() {
        Self.assertCoversTheContract()
        let appSupport = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent(Branding.displayName)
        let logURL = appSupport.appendingPathComponent("preferences.jsonl")
        self.store = PreferenceStore(logFileURL: logURL)
        // After the stored properties, because it captures self.
        watchTextEditing()
    }

    /// NOTICE WHEN SOMEONE IS TYPING, because most of this app's shortcuts are single letters.
    ///
    /// `B` adds a brush mask, `Z` keeps the photo, `X` rejects it — and there are two places where
    /// letters are also just letters: renaming a mask, and naming a mask preset. A shortcut fires
    /// from anywhere in the window, so without this, typing "black rocks" into a mask name adds a
    /// brush mask, rejects the photograph and keeps the next one.
    ///
    /// The shortcuts are UNINSTALLED while a field is editing rather than made to do nothing. A
    /// shortcut that no-ops still swallows the keystroke, so the letter would simply never appear —
    /// which is a stranger bug than the one being fixed.
    ///
    /// Belt and braces on the way out: `textDidEndEditing` is the ordinary signal, but a window that
    /// loses key while a field is focused may not send it, and a flag stuck at `true` would silently
    /// kill every single-key shortcut in the app. Resigning key or active clears it too.
    private func watchTextEditing() {
        let centre = NotificationCenter.default
        func observe(_ name: Notification.Name, _ editing: Bool) {
            centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isEditingText = editing }
            }
        }
        // Both the control's notification and the field editor's: SwiftUI's `TextField` and the
        // hand-built `NSTextField` in the preset sheet do not go through the same one.
        observe(NSControl.textDidBeginEditingNotification, true)
        observe(NSText.didBeginEditingNotification, true)
        observe(NSControl.textDidEndEditingNotification, false)
        observe(NSText.didEndEditingNotification, false)
        observe(NSWindow.didResignKeyNotification, false)
        observe(NSApplication.didResignActiveNotification, false)
    }

    /// Screenshot/demo affordance: KELVIN_DEMO_IMAGE=<path> auto-loads a photo on launch. Inert
    /// unless the variable is set.
    func loadDemoIfRequested() async {
        guard candidates.isEmpty,
              let path = ProcessInfo.processInfo.environment["KELVIN_DEMO_IMAGE"] else { return }
        await loadPhoto(from: URL(fileURLWithPath: path))
    }

    // MARK: Folder browsing + per-photo sessions

    /// The other photos sitting in the folder you opened from, for the filmstrip, in the order the
    /// strip shows them.
    var folderPhotos: [URL] = []
    /// Photos whose edit differs from the candidate Kelvin generated (drives the strip's dot).
    var editedURLs: Set<URL> = []

    // MARK: The shoot's look

    /// The look the open shoot is in, or nil if it has never been given one. See `ShootLook` for
    /// why this is one record rather than an edit per photograph.
    ///
    /// Written by `loadShootLook`, `applyLookToShoot` and `clearShootLook`, and by tests that need a
    /// shoot already in a look; nothing else should assign it. Assigning here does NOT persist —
    /// `applyLookToShoot` is the path that writes.
    var shootLook: ShootLook?
    /// Which folder `shootLook` describes, so opening a different shoot doesn't inherit the last
    /// one's look. One folder at a time, for the same reason `captureIndex` is.
    @ObservationIgnored private var shootLookFolder: URL?

    /// Point the shoot look at a folder, reading whatever was applied to it before. Cheap — one
    /// small JSON read, and only when the folder actually changes.
    func loadShootLook(for folder: URL) {
        guard shootLookFolder != folder else { return }
        shootLookFolder = folder
        shootLook = ShootLookStore.load(for: folder)
    }

    /// The style a photograph should open in, before any hand-made edit is restored on top.
    ///
    /// Nil means nothing has claimed this frame and the engine's own ranking wins — which is what
    /// every photo did before shoot looks existed, and still does in a shoot nobody has applied one
    /// to. A frame with its own override beats the shoot's style; see `ShootLook.style(for:)`.
    func effectiveStyle(for photo: URL) -> String? {
        shootLook?.style(for: photo)
    }

    /// Put the chosen look on the shoot — or on just the selected frames.
    ///
    /// **This writes one small record, not an edit per photograph.** Nothing is rendered and no file
    /// is written next to anyone's originals; the strip and the open photo simply resolve the style
    /// against each frame's own histogram from here on. Export is what makes files.
    ///
    /// An apply that covers the whole folder becomes the shoot's style and clears any override it
    /// contradicts. Anything narrower — a strip selection, or the Keep filter with nothing
    /// selected — lands as per-frame overrides and leaves the rest of the shoot alone. See
    /// `ShootLook.applying(_:to:inShootOf:)`, which is where that rule lives and is tested.
    func applyLookToShoot() {
        guard let folder = currentShootFolder else {
            statusMessage = "Open a shoot first — a look is applied to the folder you are looking at"
            return
        }
        guard let styleId = selectedCandidateId,
              let style = CandidateStyle.all.first(where: { $0.id == styleId }) else {
            statusMessage = "Pick a look first — applying it to the shoot adapts the one you have chosen"
            return
        }

        let scope = applyScope()
        let coversWholeShoot = ShootLook.covers(scope, folderPhotos)
        var look = (shootLook ?? ShootLook())
            .applying(styleId, to: scope, inShootOf: folderPhotos)
        look.appliedAt = ISO8601DateFormatter().string(from: Date())
        ShootLookStore.save(look, for: folder)
        shootLook = look
        shootLookFolder = folder

        // The photo on screen was composed against the OLD look and would otherwise sit there
        // contradicting the strip until you navigated away and back. Only when it is in scope, and
        // never over an edit somebody made by hand — that is the one thing a shoot look never wins
        // against, and silently discarding it here would be the worst version of this feature.
        //
        // Keyed on `loadedURL`, not `imageURL`: `candidates` and `isTouched` describe the frame
        // whose pixels are actually in memory, and mid-decode those are two different photographs.
        if let open = loadedURL, scope.contains(open), !isTouched {
            if candidates.contains(where: { $0.id == styleId }) {
                selectCandidate(id: styleId)
            } else if let first = candidates.first {
                // The curator dropped this style for THIS frame. Fall back to the engine's own
                // first choice — the answer reopening the photo would give — rather than leaving
                // the previous look standing, which is neither what was asked for nor what the
                // export will write.
                selectCandidate(id: first.id)
            }
        }

        // EVERY OTHER FRAME IN SCOPE THAT IS SITTING IN THE SESSION CACHE HAS TO GO.
        //
        // `openPhoto` returns early on a cached session and never reaches `loadPhoto`, which is the
        // only place the shoot look picks a candidate. So a frame browsed BEFORE this apply would
        // be restored exactly as it was — canvas showing the old look, export writing the new one,
        // and no way to tell from the strip which you were going to get.
        //
        // Hand-edited frames keep their session: a hand edit outranks the look, so nothing about
        // them changed, and dropping one would spend a decode to arrive at the same picture.
        let stale = staleSessionURLs(coveredBy: scope, cached: cachedSessionURLs)
        for url in stale {
            sessions.removeValue(forKey: url)
            sessionOrder.removeAll { $0 == url }
        }

        // Says which of the three scopes actually happened, because they are three different
        // promises. "This shoot is in Vivid" over a kept-only apply is a lie the record no longer
        // tells and the status line must not either.
        let n = scope.count, s = scope.count == 1 ? "" : "s"
        let base: String
        if coversWholeShoot {
            base = "This shoot is in \(style.label) — \(n) photo\(s), each adapted to its own frame"
        } else if selectedPhotos.isEmpty {
            base = "\(n) kept photo\(s) set to \(style.label) — rejected and undecided frames are "
                + "unchanged"
        } else {
            base = "\(n) selected frame\(s) set to \(style.label) — the rest of the shoot is unchanged"
        }
        let settled = base + ". Export edited writes the files"
        statusMessage = settled

        // Start reading the frames nobody has opened yet. Applying a look is the moment someone
        // commits to the shoot, and it is the last moment before export at which six seconds a
        // frame can be spent without anybody waiting on it.
        //
        // The count arrives with the seed rather than before it: the unread filter runs off the
        // main actor, so reading `shootReadTotal` on the next line quoted whatever the last
        // neighborhood seed had left there — usually 0, occasionally 16 out of a 400-frame shoot.
        // Only rewrite the line if it is still the one this apply wrote; a seed landing after the
        // user has done something else must not talk over what that something else said.
        readShootAhead { [weak self] unread in
            guard let self, unread > 0, self.statusMessage == settled else { return }
            self.statusMessage = base + " · reading \(unread) of them now, so export doesn't have to"
        }
    }

    /// The frames `applyLookToShoot` will claim: the selection if there is one, otherwise the whole
    /// shoot narrowed by the Keep flag when asked. Pure, so the rule is testable without a window.
    func applyScope() -> [URL] {
        guard selectedPhotos.isEmpty else {
            return folderPhotos.filter { selectedPhotos.contains($0) }
        }
        return batchTargets(keepersOnly: batchKeepersOnly)
    }

    // MARK: Reading the shoot ahead of time

    /// How far the background read has got. Zero total means nothing is running.
    private(set) var shootReadDone = 0
    private(set) var shootReadTotal = 0

    /// ONE queue, one loop, one progress surface. Both background-read callers feed the same
    /// engine: `applyLookToShoot` seeds the full scope (`readShootAhead`), browsing seeds the
    /// sixteen nearest unread frames (`seedNeighborhoodRead`). The policy — ordering, dedupe,
    /// the energy bound, what a stop suppresses — lives in `ReadAheadQueue`, where it is tested.
    @ObservationIgnored private var readQueue = ReadAheadQueue()
    /// The single loop draining `readQueue`. Started by `ensureReadLoop`, ended by teardown or
    /// by the queue running dry.
    @ObservationIgnored private var readLoopTask: Task<Void, Never>?
    /// The background read currently ON THE MODEL, held separately from the loop so the
    /// foreground can cancel the generation without killing the loop — the provider checks
    /// cancellation mid-generation, the loop catches it and re-enqueues the frame. See the
    /// perceive site in `loadPhoto`.
    @ObservationIgnored private var backgroundReadTask: Task<Perception, Error>?
    /// The neighborhood being computed off the main actor, so a seed for a photo the user has
    /// already left never lands.
    @ObservationIgnored private var seedTask: Task<Void, Never>?
    /// The whole-shoot sweep's own seed, held apart from the neighborhood's.
    ///
    /// They shared one slot, and the mode guard that was supposed to keep browsing from outranking
    /// a sweep is blind to a sweep whose scope filter is still running. So pressing Apply and then
    /// touching the strip — which is exactly what someone does next, since the whole point is that
    /// the read happens while they carry on culling — cancelled the sweep outright, and nothing
    /// ever re-seeded it. Export then paid the perception cost per frame, with someone waiting.
    @ObservationIgnored private var sweepSeedTask: Task<Void, Never>?

    var isReadingShoot: Bool { shootReadTotal > 0 && shootReadDone < shootReadTotal }
    /// Whether the current read is the whole-shoot sweep (Apply) rather than the browsing
    /// neighborhood — the toolbar words them differently, because "Reading 5/16" over a
    /// 110-frame folder made the owner ask what the 16 was.
    var isSweepingShoot: Bool { readQueue.mode == .sweep }

    /// Read every frame the look covers that has not been read yet, in the background.
    ///
    /// **This is the difference between a two-minute export and a forty-five-minute one.** Measured
    /// over 25 frames at 24 MP, perception is 96% of what exporting a look-carried frame costs, and
    /// export used to pay it per frame, at the moment someone was waiting for files. Doing it here
    /// moves the same seconds to the moment they have just told the app what they want and are about
    /// to go on culling — and `PerceptionStore` means it is paid once, ever, per photograph.
    ///
    /// It yields to the photograph on screen. The provider is an actor with one read in flight, so a
    /// background read that queued ahead of the frame someone just clicked would make browsing feel
    /// broken — which is a worse bug than the slow export this fixes.
    /// - Parameter announce: called on the main actor once the sweep is actually seeded, with the
    ///   number of frames it will read. The count cannot be read back synchronously — the scope
    ///   filter is a `stat` and a JSON decode per frame and runs off the main actor — so the caller
    ///   that wants to say "reading 400 of them now" has to be told, rather than ask.
    func readShootAhead(announce: (@MainActor @Sendable (Int) -> Void)? = nil) {
        sweepSeedTask?.cancel()
        let modelId = perceptionProvider.activeModelID
        let scope = applyScope()
        sweepSeedTask = Task { [weak self] in
            // The unread filter is a `stat` and a JSON decode per frame OF THE WHOLE SCOPE, at
            // the moment Apply was clicked — off the main actor, like the neighborhood seed and
            // every other per-file pass in this file. Same pattern, previously applied to one
            // seeder and not the other.
            let targets = await Offload.run(.io) {
                scope.filter { PerceptionStore.load(for: $0, modelId: modelId) == nil }
            }
            guard let self, !Task.isCancelled else { return }
            self.readQueue.seedSweep(targets)
            self.publishReadProgress()
            self.ensureReadLoop()
            announce?(self.shootReadTotal)
        }
    }

    /// Read the frames AROUND the photo on screen while nobody is waiting — so arrowing on to the
    /// next frame meets a scene that is already read instead of a six-second wait.
    ///
    /// Seeded automatically: at the end of every `loadPhoto`, when a cached session is restored,
    /// and again when the capture index lands and re-sorts the strip (the neighbors change with
    /// the order). Deliberately bounded to `ReadAheadQueue.neighborhoodSize` frames and re-seeded
    /// as the anchor moves — the automatic queue never grows beyond the neighborhood. The
    /// whole-shoot sweep stays where it is: on the Apply button, where the intent is explicit.
    func seedNeighborhoodRead() {
        // A sweep outranks browsing, and a halt means the user said stop; `seedNeighborhood`
        // refuses both, but checking here too saves computing a neighborhood only to drop it.
        guard readQueue.mode == .idle || readQueue.mode == .neighborhood else { return }
        guard let anchor = imageURL, folderPhotos.count > 1 else { return }
        let folder = folderPhotos
        let modelId = perceptionProvider.activeModelID
        seedTask?.cancel()
        seedTask = Task { [weak self] in
            // The unread filter is a `stat` and a JSON read per neighbor, and the walk visits
            // more than it keeps once nearby frames are read — off the main actor, like every
            // other per-file pass in this file.
            let picks = await Offload.run(.io, qos: .utility) {
                ReadAheadQueue.neighborhood(around: anchor, in: folder) {
                    PerceptionStore.load(for: $0, modelId: modelId) == nil
                }
            }
            guard let self, !Task.isCancelled, self.imageURL == anchor else { return }
            self.readQueue.seedNeighborhood(picks)
            self.publishReadProgress()
            self.ensureReadLoop()
        }
    }

    private func publishReadProgress() {
        shootReadTotal = readQueue.total
        shootReadDone = readQueue.done
    }

    private func ensureReadLoop() {
        guard readLoopTask == nil, readQueue.hasWork else { return }
        readLoopTask = Task { [weak self] in
            await self?.runReadLoop()
            guard !Task.isCancelled, let self else { return }
            self.readLoopTask = nil
            self.publishReadProgress()
            // A seed can land between the loop running dry and this line — it saw a live
            // `readLoopTask` and declined to start another. Nobody else will, so check.
            self.ensureReadLoop()
        }
    }

    /// The one loop that drains `readQueue`, whoever seeded it.
    ///
    /// Per frame: decode + proxy (detached, background priority), then the model. The NEXT
    /// frame's decode starts while this frame is on the model — decode is 0.3–1.2 s of a 5–6.5 s
    /// frame and used to run strictly after the previous inference in every path. At most ONE
    /// decode runs ahead, because a decode transiently holds a full 60 MP frame (~100+ MB);
    /// only the materialised 768 px proxy outlives it (see `decodeReadProxy`).
    private func runReadLoop() async {
        // The frame after the in-flight one, decoding while the model works.
        var decodeAhead: (url: URL, task: Task<ReadAheadProxy, Error>)?
        // The proxy of a frame whose read the foreground preempted — kept (it is a small 768 px
        // bitmap, not the decode) so the retry skips straight to the model.
        var preempted: (url: URL, proxy: CIImage)?
        while !Task.isCancelled {
            // Yield to the photograph on screen, to export and to share — between frames, on the
            // same 200 ms poll the sweep has always used. Mid-frame preemption is the
            // foreground's move, via `backgroundReadTask`.
            while ReadAheadQueue.mustYield(isProcessing: isProcessing,
                                           isPreparingShare: isPreparingShare), !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if Task.isCancelled { break }
            guard let url = readQueue.next() else { break }
            // Re-check the store at CLAIM time, not just at seed time: during a sweep the
            // foreground may have read and saved this exact frame (a sweep is never re-seeded),
            // and a six-second generation for an answer already on disk is the one duplicate an
            // audit found this loop could still spend.
            if PerceptionStore.load(for: url, modelId: perceptionProvider.activeModelID) != nil {
                readQueue.markDone()
                publishReadProgress()
                continue
            }
            publishReadProgress()
            let modelId = perceptionProvider.activeModelID
            do {
                let proxy: CIImage
                if let held = preempted, held.url == url {
                    proxy = held.proxy
                } else if let ahead = decodeAhead, ahead.url == url {
                    decodeAhead = nil
                    proxy = try await ahead.task.value.proxy
                } else {
                    proxy = try await Self.decodeReadProxy(url).value.proxy
                }
                preempted = nil
                // A decode warmed for a frame the queue no longer has next — a re-seed moved the
                // neighborhood — is money already spent; drop it rather than read the wrong frame.
                if let ahead = decodeAhead, ahead.url != readQueue.upcoming {
                    ahead.task.cancel()
                    decodeAhead = nil
                }
                // PIPELINE: start the next frame's decode now, while this frame is on the model.
                if decodeAhead == nil, let upcoming = readQueue.upcoming {
                    decodeAhead = (upcoming, Self.decodeReadProxy(upcoming))
                }
                if Task.isCancelled { break }
                // The read itself, in its own task so the FOREGROUND can cancel it without
                // cancelling this loop. The provider checks cancellation mid-generation.
                let job = Task { [perceptionProvider] in
                    try await perceptionProvider.perceive(proxy)
                }
                backgroundReadTask = job
                do {
                    let read = try await job.value
                    backgroundReadTask = nil
                    // Saved only on a COMPLETED read. The provider re-checks cancellation after
                    // the generation returns — a cancelled stream finishes NORMALLY with partial
                    // text rather than throwing — so a preempted read leaves `job` as
                    // `CancellationError`, never as a parseable-looking partial.
                    PerceptionStore.save(read, for: url, modelId: modelId)
                    readingNotes[url] = .some(read.notes)
                    readQueue.markDone()
                } catch {
                    backgroundReadTask = nil
                    // Preemption arrives two ways and BOTH must requeue, not skip: as
                    // `CancellationError` (the provider's post-generation check), or — if any
                    // future path swallows that — as whatever error a half-generated read
                    // produced while `job` stood cancelled. The job's own flag is the truth;
                    // an audit found the error-type test alone silently dropping preempted
                    // frames from a sweep, each one a six-second cost at export time.
                    if error is CancellationError || job.isCancelled {
                        // The whole read-ahead being torn down (stop button, shoot change)
                        // cancels THIS loop too — go; the queue was cleared by the teardown.
                        if Task.isCancelled { break }
                        // The foreground took the model back mid-generation. Put the frame
                        // back at the head — nothing was saved — and wait out the load at the
                        // top of the loop; the retry reuses the proxy held above.
                        preempted = (url, proxy)
                        readQueue.requeue()
                    } else {
                        // The model genuinely failed on this frame. Same rule as a failed
                        // decode below: swallowed, counted, and the sweep moves on.
                        readQueue.markDone()
                    }
                }
            } catch {
                // A frame that will not decode is not a failure of the sweep — export reports
                // it by name when it gets there. Counted done, so progress keeps moving —
                // whatever the decode threw, the claim must be resolved or the loop would
                // leave a frame dangling in the count.
                readQueue.markDone()
            }
            publishReadProgress()
        }
        decodeAhead?.task.cancel()
    }

    /// A materialised 768 px perception proxy, boxed to cross the actor boundary on the same
    /// promise `DecodedForExport` makes: read-only `CIImage`, safe for concurrent reads.
    private struct ReadAheadProxy: @unchecked Sendable {
        let proxy: CIImage
    }

    /// Decode one frame and hand back ONLY its perception proxy. The full-resolution decode
    /// lives and dies inside the `autoreleasepool` — the read-ahead never holds a 60 MP frame
    /// beyond the downsample, which is what makes running one decode ahead affordable.
    ///
    /// On the decode lane at LOW priority, behind anything the foreground asks for: the photograph
    /// on screen must never queue behind one nobody is looking at yet. `.utility` rather than
    /// `.background` QoS, because the lane is serial and a background-throttled decode at its head
    /// would hold up a foreground decode queued behind it — the old priority inversion in new
    /// clothes. The lane and its own context are what keep this decode from ever holding a lock
    /// the preview or the candidate build is waiting on; see `Offload`.
    private nonisolated static func decodeReadProxy(_ url: URL) -> Task<ReadAheadProxy, Error> {
        Task {
            try await Offload.run(.decode, qos: .utility, priority: .low) {
                try autoreleasepool {
                    let image = try ImageDecoder.decode(url: url)
                    return ReadAheadProxy(
                        proxy: Self.materialiseDecoded(PerceptionProxy.downsample(image)))
                }
            }
        }
    }

    /// The toolbar's stop button. It means STOP: the queue empties and automatic seeding stays
    /// suppressed until the shoot changes or the user explicitly applies a look — otherwise the
    /// next arrow key would quietly restart the thing they just turned off.
    func stopReadingShoot() {
        tearDownReadAhead(halting: true)
    }

    /// Leaving the shoot ends the read-ahead with it, but the NEXT folder starts clean.
    func resetReadAhead() {
        tearDownReadAhead(halting: false)
    }

    /// Everything that has to stop before `exit()` may run: the read-ahead, the in-flight read,
    /// the scans. Synchronous — see `DocumentOpenDelegate.applicationShouldTerminate` for why it
    /// must not live inside a Task. `awaitQuiescenceForQuit` is the wait that follows.
    func cancelForQuit() {
        tearDownReadAhead(halting: true)
        perceiveTask?.cancel(); perceiveTask = nil
        scanTask?.cancel()
        captureIndexTask?.cancel()
        hashTask?.cancel()
        // The batch export too. Its loop checks for cancellation between frames, and a frame
        // mid-write finishes through `ImageWriter`'s rename-into-place, so nothing half-written
        // ever sits under a real name. Without this the export kept decoding and perceiving
        // through the grace period, and a quit that sampled the lanes between two of its frames
        // could read as clean and `exit()` under the next generation.
        exportTask?.cancel()
    }

    /// Wait — briefly — for the model and the GPU lanes to let go. Returns whether they did; the
    /// caller leaves through `_exit` when they did not, because `exit()` under a thread that is
    /// still inside MLX or mid-command-buffer in Core Image aborts in Metal (the crash reports of
    /// 21 August 2026).
    ///
    /// A GENERATION is waited for — a cancelled one ends within a token or two. A model load is
    /// not: it cannot be interrupted, and two seconds of nothing before a quit is the wrong way
    /// to spend them. `isBusy` still reports it, so the caller takes the `_exit` route.
    func awaitQuiescenceForQuit() async -> Bool {
        //
        // AND IF ANYTHING WAS BUSY WHEN QUIT WAS ASKED FOR, THE ANSWER IS "NOT CLEAN" EVEN AFTER THE
        // WAIT. `isGenerating` drops when `perceive` returns — but a cancelled generation returns
        // while mlx-swift-lm's own token task is still finishing the step it was on, and an
        // `exit()` in that window ran the destructors under it and crashed (caught by the drag
        // harness on 21 August 2026, after three hand tests had passed on timing). There is no
        // way to see that inner task from here, so: busy at the moment of asking means the process
        // leaves through `_exit`, which skips the destructors. Nothing is lost — edits are on
        // disk as they are made — and the wait still lets a render or an export finish its file.
        // EVERY lane, not only the three that obviously render: the vision lane measures masks
        // through Core Image, the scan lane decodes RAWs for the focus check, and thumbnails are
        // renders too. Any of them mid-command-buffer at `exit()` is the same Metal abort.
        func gpuBusy() -> Bool {
            Offload.Lane.allCases.reduce(0) { $0 + Offload.depth(of: $1) } > 0
        }
        // An export in flight counts as busy even if the lanes happen to be empty at this
        // instant — it is between frames, and its next one starts a generation or a render a
        // moment later. `_exit` is the deliberate route; the files already written are whole.
        let wasBusy = perceptionProvider.isBusy || gpuBusy() || isExporting
        let deadline = Date().addingTimeInterval(2)
        while gpuBusy() || perceptionProvider.isGenerating, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !wasBusy && !perceptionProvider.isBusy && !gpuBusy()
    }

    private func tearDownReadAhead(halting: Bool) {
        seedTask?.cancel(); seedTask = nil
        // Both seeders, or a sweep seeded a moment before the user pressed stop would land after
        // the teardown and start the loop again.
        sweepSeedTask?.cancel(); sweepSeedTask = nil
        // The in-flight generation dies mid-token — the provider checks — and never saves.
        backgroundReadTask?.cancel(); backgroundReadTask = nil
        readLoopTask?.cancel(); readLoopTask = nil
        if halting { readQueue.halt() } else { readQueue.reset() }
        publishReadProgress()
    }

    /// Take the look back off the shoot. One record removed, rather than a sweep through a folder
    /// deleting four hundred edits — which is the whole reason the record exists.
    ///
    /// Hand-made edits are deliberately left alone: they were never part of the look, and this is a
    /// button someone presses to undo an experiment, not to lose an afternoon's work.
    func clearShootLook() {
        guard let folder = currentShootFolder, shootLook != nil else { return }
        ShootLookStore.remove(for: folder)
        shootLook = nil
        statusMessage = "Look removed from this shoot — hand-made edits are untouched"
    }

    /// The folder the open shoot lives in. Nil when nothing is open.
    var currentShootFolder: URL? {
        imageURL?.deletingLastPathComponent() ?? folderPhotos.first?.deletingLastPathComponent()
    }

    /// How many frames the shoot's look currently claims, for the label on the control.
    var shootLookCount: Int {
        guard shootLook != nil else { return 0 }
        return folderPhotos.filter { effectiveStyle(for: $0) != nil }.count
    }

    /// What the apply control says it will do. It names the scope because the same button means two
    /// different things depending on whether anything is selected, and a control that does not say
    /// which is how someone restyles four hundred frames meaning to restyle four.
    var applyButtonLabel: String {
        let scope = applyScope()
        if !selectedPhotos.isEmpty { return "Apply to \(selectedPhotos.count) selected" }
        // "Apply to shoot" over a Kept-only scope names a folder and touches a fraction of it.
        if !ShootLook.covers(scope, folderPhotos) { return "Apply to \(scope.count) kept" }
        return "Apply to shoot"
    }

    var applyButtonHelp: String {
        let style = selectedCandidateId.flatMap { id in
            CandidateStyle.all.first { $0.id == id }
        }?.label ?? "the chosen look"
        let scope = applyScope()
        let n = scope.count, s = n == 1 ? "" : "s"
        let adapted = " Each frame is read and corrected on its own — the style is adapted, never "
            + "copied. Nothing is written until you export."
        if !selectedPhotos.isEmpty {
            return "Put \(style) on just the \(n) selected frame\(s). The rest of the shoot keeps "
                + "the look it has."
        }
        if !ShootLook.covers(scope, folderPhotos) {
            return "Put \(style) on just the \(n) frame\(s) flagged Keep. Rejected and undecided "
                + "frames keep the look they have."
        }
        return "Put \(style) on all \(n) photo\(s) in this shoot." + adapted
    }

    // MARK: Strip selection
    //
    // Selection exists so a look can land on SOME of the shoot. It is deliberately separate from
    // `imageURL` — the frame you are looking at and the frames you are acting on are different
    // questions, and conflating them means you cannot see one photograph while changing another.

    /// The frames picked out in the strip. Empty means "the whole shoot", which is what every
    /// action here defaults to.
    var selectedPhotos: Set<URL> = []
    /// The anchor a shift-click extends from — the last frame clicked without shift.
    @ObservationIgnored private var selectionAnchor: URL?

    /// A click in the strip, with whatever modifiers were held.
    ///
    /// Plain click opens the photograph and drops the selection, because that is what clicking a
    /// thumbnail has always done and a selection nobody can see themselves leaving is a trap.
    /// Command adds or removes one frame; shift extends from the anchor.
    ///
    /// **Extending walks `visiblePhotos`, not `folderPhotos`** — what is on screen, in the order it
    /// is on screen. Walking the full folder instead would sweep up frames the filter is hiding:
    /// shift-click across a strip filtered to keepers and you would silently select the rejects
    /// sitting between them, then apply a look to photographs you had already thrown out.
    func stripClick(_ url: URL, extend: Bool, toggle: Bool) {
        if toggle {
            if selectedPhotos.contains(url) { selectedPhotos.remove(url) }
            else { selectedPhotos.insert(url); selectionAnchor = url }
            return
        }
        let strip = visiblePhotos
        if extend, let anchor = selectionAnchor,
           let a = strip.firstIndex(of: anchor), let b = strip.firstIndex(of: url) {
            selectedPhotos = Set(strip[min(a, b)...max(a, b)])
            return
        }
        selectedPhotos = []
        selectionAnchor = url
        Task { await openPhoto(url) }
    }

    /// Everything the strip is showing — again not the whole folder, for the same reason. "Select
    /// all" over frames you cannot see is how a filter becomes a trap.
    func selectAllPhotos() {
        let strip = visiblePhotos
        selectedPhotos = Set(strip)
        selectionAnchor = strip.first
    }

    func clearSelection() {
        selectedPhotos = []
        selectionAnchor = nil
    }

    // MARK: Strip order
    //
    // The strip sorted by filename, which is only a proxy for the order the frames were taken in:
    // two bodies, two cards, a renamed export or a frame counter past 9999 all interleave wrongly
    // and there was no way to say so. The rules live in `PhotoOrder` (KelvinCore) so they are
    // testable without a window; what lives here is when to re-sort and where the dates come from.

    /// Time, because "the shoot in order" means time. Not persisted: which order a folder wants is
    /// a property of the folder — a wedding wants time, a folder of numbered scans wants names —
    /// so carrying last week's choice into an unrelated shoot would be a worse guess than the
    /// default is.
    var photoSort: PhotoSortKey = .captureTime { didSet { reorderFolderPhotos() } }
    var photoSortReversed = false { didSet { reorderFolderPhotos() } }

    /// When and where each photo in `captureIndexFolder` was taken. Empty until the background read
    /// lands, which `PhotoOrder.sorted` treats as "nothing is dated" — so the strip shows filename
    /// order in the meantime rather than an empty or jumping list.
    ///
    /// One index rather than a dates dictionary, because grouping by place needs the positions and
    /// they come out of the SAME header read. Reading the folder twice to get them separately would
    /// double the slowest part of opening a shoot.
    /// Written by `loadCaptureIndex` and by tests that need a folder with known dates and positions;
    /// nothing else should assign it.
    var captureIndex = PhotoOrder.CaptureIndex()
    /// Which directory `captureIndex` describes. One folder at a time, which is how a shoot is
    /// worked: opening every frame of a 437-shot folder must not re-read 437 EXIF headers each
    /// time. Leaving for another folder and coming back costs one re-read, which is the price of
    /// not carrying an unbounded cache of dates for folders nobody is looking at.
    @ObservationIgnored private var captureIndexFolder: URL?
    @ObservationIgnored private var captureIndexTask: Task<Void, Never>?
    /// True while the read is in flight, so the strip's sort control can say the order is not
    /// settled yet instead of appearing to have sorted wrongly.
    private(set) var captureInfoPending = false

    /// Whether the order on screen is still provisional. Only true under capture-time sort — the
    /// read also runs when you are sorting by name (so switching later is instant), but a name
    /// sort is not waiting on it and must not display as though it were.
    var sortOrderPending: Bool { captureInfoPending && photoSort == .captureTime }

    /// Put `folderPhotos` back in the order the controls currently ask for. Cheap — a sort of a
    /// few hundred URLs against an in-memory dictionary, no file access.
    private func reorderFolderPhotos() {
        folderPhotos = PhotoOrder.sorted(folderPhotos, by: photoSort,
                                         reversed: photoSortReversed, captureDates: captureIndex.dates)
    }

    /// The per-file work a filmstrip needs — capture times, which photos carry edits, which are
    /// flagged — run only when the strip is actually on screen.
    ///
    /// Deferred rather than dropped: the strip still shows everything the moment you open it. What
    /// changed is that opening a single photograph no longer pays for a shoot you did not ask to
    /// see. Called again when the strip is unfolded, and idempotent, so the cost lands once.
    func loadFolderDetailIfVisible(for folder: URL, photos: [URL]) {
        guard UserDefaults.standard.bool(forKey: FilmstripFold.expandedKey) else {
            pendingFolderDetail = (folder, photos)
            return
        }
        pendingFolderDetail = nil
        loadCaptureIndex(for: folder, photos: photos)
        loadEditedMarkers(among: photos)
        // In memory already — `FlagStore` keeps the whole map and this is a dictionary lookup per
        // frame, no filesystem at all. Stays synchronous.
        flags = FlagStore.flags(among: photos)
    }

    /// Which frames carry a saved edit, for the strip's dots.
    ///
    /// One `stat` per frame, in Application Support rather than on the user's volume — so this is
    /// never the slow one, even over a share. Off the main actor anyway: 437 stats is 437 stats, and
    /// this class has twice put the window on the floor by doing per-file work on the main thread.
    private func loadEditedMarkers(among photos: [URL]) {
        Task { [weak self] in
            let edited = await Offload.run(.io, qos: .utility) {
                EditStore.edited(among: photos)
            }
            self?.editedURLs.formUnion(edited)
        }
    }

    /// The folder whose detail has not been read yet, held so unfolding the strip can pay the cost
    /// then instead of on open.
    @ObservationIgnored private var pendingFolderDetail: (folder: URL, photos: [URL])?

    /// Called when the strip is unfolded. Pays the deferred cost, once.
    func filmstripDidExpand() {
        guard let pending = pendingFolderDetail else { return }
        pendingFolderDetail = nil
        loadCaptureIndex(for: pending.folder, photos: pending.photos)
        loadEditedMarkers(among: pending.photos)
        flags = FlagStore.flags(among: pending.photos)
    }

    /// Read when and where each frame was taken, **off the main thread**, and re-sort when it lands.
    ///
    /// An EXIF read is a header read, not a decode, so it is cheap per file — but 437 files is 437
    /// file opens, and this codebase has twice put the window on the floor by doing per-file work
    /// on the main thread (thumbnails once decoded whole RAWs during view layout and the window
    /// never appeared). So: never on the main thread, never blocking the open, and the strip is
    /// usable in filename order throughout.
    private func loadCaptureIndex(for folder: URL, photos: [URL]) {
        guard captureIndexFolder != folder else { return }      // already have this folder
        captureIndexTask?.cancel()
        captureIndexFolder = folder
        captureIndex = PhotoOrder.CaptureIndex()
        captureInfoPending = true
        // The one place that knows the shoot has changed, so it is where everything keyed to the
        // OLD shoot is let go of.
        //
        // The scan is the expensive one: the fast path reads a RAW's embedded preview and serves
        // repeat visits from `MediaCache`, but a first pass over bodies that embed no usable
        // preview is still a full decode per frame — and an abandoned scan used to carry on
        // regardless and hold the progress flag that stops the next folder's scan
        // from ever starting. The dictionaries are cheap each but unbounded across a session — the
        // thumbnail cache is ~68 KB a frame, so five shoots is ~150 MB of 160 px previews for
        // folders nobody has open, and it was never cleared anywhere.
        scanTask?.cancel()
        scanEpoch += 1        // the cancelled scan's epilogue must not touch the next folder's state
        focusScanProgress = nil
        focusScanETA = nil
        let keep = Set(photos)
        thumbnails = thumbnails.filter { keep.contains($0.key) }
        focus = focus.filter { keep.contains($0.key) }
        triage = triage.filter { keep.contains($0.key) }
        captureIndexTask = Task { [weak self] in
            let index = await Offload.run(.io, qos: .utility) {
                // Through the cache rather than `PhotoOrder.captureIndex` directly. The ordering
                // rules stay in `PhotoOrder` where they are tested; the difference is only that a
                // folder opened yesterday does not re-read 437 EXIF headers to draw the same strip.
                // Locally that saves a second; over SMB it is the dominant cost of opening a shoot.
                MediaCache.shared.captureIndex(for: photos)
            }
            guard !Task.isCancelled, let self else { return }
            // Guard against a folder switch that started while this read was running — a late
            // result must not re-sort the strip you are looking at now using another folder's
            // dates.
            guard self.captureIndexFolder == folder else { return }
            self.captureIndex = index
            self.captureInfoPending = false
            self.reorderFolderPhotos()
            // The strip may just have re-sorted into capture order, which changes who the open
            // photo's NEIGHBORS are — re-seed the read-ahead around the same anchor in the new
            // order. This is also the folder-open seed: on open, the index landing is the moment
            // the shoot's real order is known.
            self.seedNeighborhoodRead()
            // A folder with no positions in it cannot be grouped by place, and leaving the lens
            // selected would partition the shoot into one group called "No location" — which looks
            // like the grouping is broken rather than like the files have no GPS. The menu says why
            // the choice is unavailable; the strip goes back to flat.
            if self.stripGrouping == .place, !index.hasAnyLocation {
                self.stripGrouping = .none
            }
            // A NEW SHOOT NEEDS ITS OWN MEASUREMENTS, and the filter cannot ask for them because it
            // did not change. `stripFilter`'s `didSet` starts the scan when you SELECT `Best`, but
            // selecting a folder is the other half of the same question: this method has just
            // dropped the previous shoot's `triage`, so a filter that was filtering a moment ago is
            // now reading an empty dictionary and showing everything. Nothing would ever have
            // started a scan for the new folder — the identical defect the filter's `didSet` fixes,
            // reached through the other door.
            //
            // Here rather than at the top of `loadCaptureIndex` because `scanFocus` measures
            // `folderPhotos`, and this is the point at which that is known to be the new shoot —
            // `reorderFolderPhotos` above has just sorted it.
            if self.stripFilter.needsScan { self.scanFocus() }
            // Ask for the place names now the positions are known. One lookup per distinct rounded
            // coordinate, so a shoot in one valley costs a single request rather than four hundred —
            // and nothing happens at all when the setting is off.
            PlaceNames.shared.resolveAll(Array(index.locations.values))
        }
    }

    // MARK: Culling — deciding what stays, before editing what's left
    //
    // A folder is often two hundred frames and the workspace showed all of them, which is the
    // thing that makes a shoot feel unmanageable. The established answer is to decide first and
    // edit second: one binary decision per frame, driven from the keyboard, then hide everything
    // you rejected. Ratings and colour labels are deliberately absent — dozens of possible states
    // per photo is what makes culling slow.

    /// Keep/reject per photo, loaded for the current folder.
    var flags: [URL: PhotoFlag] = [:]

    /// Which frames the strip is showing.
    enum StripFilter: String, CaseIterable {
        case all = "All", keepers = "Keepers", undecided = "Undecided"
        case edited = "Edited", soft = "Focus", flagged = "Flagged"
        case best = "Best"

        /// Whether this filter can only be answered by the triage scan.
        ///
        /// `Keepers`, `Undecided` and `Edited` read decisions the photographer made by hand, so they
        /// are correct the instant a folder opens. These three read MEASUREMENTS: `Best` needs the
        /// near-duplicate fingerprints, `Focus` the acuity reading, `Flagged` the concerns. On an
        /// unmeasured folder none of them has anything to filter on.
        var needsScan: Bool {
            switch self {
            case .best, .soft, .flagged: return true
            case .all, .keepers, .undecided, .edited: return false
            }
        }
    }
    var stripFilter: StripFilter = .all {
        didSet {
            // ASKING FOR THE ANSWER IS ASKING FOR THE MEASUREMENT — the same rule `stripGrouping`
            // already applies to the `Similar` lens, and the reasoning recorded there applies here
            // word for word: a control that appears to do nothing on any folder nobody happens to
            // have scanned yet is indistinguishable from a broken control.
            //
            // `Best` was shipped without it and was reported as broken within the hour, twice. It
            // was not broken. On a folder with no fingerprints every frame is its own run of one,
            // every frame is the sharpest of its run, and the filter honestly returns the whole
            // shoot — and nothing anywhere was ever going to start the scan that would change that
            // answer, because only the `Similar` lens started one. Waiting did not help, which is
            // why it looked broken both before AND after "a scan" that had never actually run.
            //
            // Measured on the owner's 437-frame shoot: 148 groups, 109 of them holding more than
            // one frame. `Best` has two thirds of that shoot to hide and could not see any of it.
            //
            // Idempotent — `scanFocus` guards on a scan already running and returns immediately
            // once every frame in the folder has a verdict.
            if stripFilter.needsScan { scanFocus() }
        }
    }

    /// Photos the strip should actually display, after the filter. The frame you are editing is
    /// always included — filtering the open photo out from under yourself is disorienting.
    var visiblePhotos: [URL] {
        // Hoisted, and ONLY for the filter that needs it. `sharpestOfSimilarRuns` sorts and
        // re-groups the whole folder; evaluating it inside the closure would do that once per
        // photograph, which on a 438-frame shoot is the same shape as the bug that made the strip
        // nine tenths of the cost of a slider drag before `LazyHStack` (see `grid`).
        let best = stripFilter == .best ? sharpestOfSimilarRuns : []
        return folderPhotos.filter { url in
            if url == imageURL { return true }
            switch stripFilter {
            case .all:       return flags[url] != .reject
            case .keepers:   return flags[url] == .keep
            case .undecided: return flags[url] == nil
            // What you have actually worked on. The strip has drawn a dot for this since the
            // filmstrip existed; it just could not be filtered on, which is the half that makes it
            // useful — "show me the twenty I edited" is the last step of a shoot.
            case .edited:    return editedURLs.contains(url)
            // Review, not a verdict: this is the list to LOOK at, so the false positives are
            // the point of it rather than something hidden by it.
            case .soft:      return focus[url]?.isSoft == true
            // EVERYTHING THE SCAN NOTICED, which `Focus` deliberately is not. The scan reports four
            // concerns and only the two about sharpness could be filtered on — a frame flagged
            // `veryDark` or `veryBright` drew a badge on its thumbnail and then could not be
            // gathered up, so the one action those flags exist to enable (look at them together,
            // decide, move on) meant scrolling the whole shoot hunting for triangles.
            case .flagged:   return isFlaggedByScan(url)
            // ONE FRAME PER GROUP OF ALIKE — the sharpest of each. This is the marker on the
            // thumbnail (`sharpestInRun`, the scope icon) turned into something you can act on:
            // the mark answered "which of these six" and then left you scrolling past the other
            // five anyway.
            case .best:      return best.contains(url)
            }
        }
    }

    /// The sharpest frame of every near-duplicate run in the folder, plus every frame the scan has
    /// not fingerprinted yet.
    ///
    /// **Computed from `folderPhotos`, not `visiblePhotos`, and that is structural rather than a
    /// preference**: `visiblePhotos` consumes this to answer `.best`, so deriving it from the
    /// filtered list would recurse. It also happens to be the right answer — which frames are alike
    /// is a fact about the shoot, not about what the strip is currently showing.
    ///
    /// Unfingerprinted frames are INCLUDED. "No signature yet" is not the same claim as "this is a
    /// duplicate", and the cost of the two mistakes is not symmetric: showing a frame that later
    /// turns out to be a near-duplicate wastes a glance, while hiding one because the scan has not
    /// reached it yet loses a photograph from the view with nothing to tell you it happened. The set
    /// tightens on its own as the scan lands.
    ///
    /// A run of one contributes its single frame, so this reads as "the shoot with the duplicates
    /// collapsed" rather than "only frames that carry the marker" — the latter would empty the strip
    /// for any shoot without bursts in it, which is most of them.
    /// `Best` is selected and there is nothing for it to work from.
    ///
    /// Which frames are alike comes from the scan's fingerprints. With none, every frame is its own
    /// run of one, every frame is the sharpest of its run, and the filter returns the whole shoot —
    /// honest, useless, and indistinguishable from a filter that does not work. It shipped that way
    /// and was reported within the hour as "the best filtering of the sharpest not working", which
    /// is exactly right.
    ///
    /// The fix is a notice rather than a different rule. Including unfingerprinted frames is still
    /// correct *during* a scan — a half-measured shoot should not hide the half it has not reached —
    /// so the rule stays and the empty case explains itself.
    var bestFilterNeedsScan: Bool { bestFilterNote != nil }

    /// Why `Best` is showing more than it should, or nil when it is showing exactly what it means.
    ///
    /// Two states produce the same useless-looking result and they need different sentences:
    ///
    ///   • **Nothing scanned.** Every frame is its own run of one, so `Best` returns the shoot.
    ///   • **Partly scanned.** Unmeasured frames are deliberately included, so `Best` returns the
    ///     measured picks PLUS everything the scan has not reached — which on a 126-frame shoot
    ///     a few seconds in is essentially the whole thing. This is the state that made the fix
    ///     for the first one look like it had not worked, because the answer barely changes until
    ///     the scan finishes.
    ///
    /// Saying the count is the point. "Best needs the scan" on a shoot that is 90% measured is a
    /// lie; "112 of 126 still to measure" tells you to wait, and "14 still to measure" tells you
    /// the answer you are looking at is nearly right.
    var bestFilterNote: String? {
        guard stripFilter == .best else { return nil }
        let pending = folderPhotos.filter { triage[$0] == nil }.count
        guard pending > 0 else { return nil }
        if pending == folderPhotos.count {
            return "Nothing measured yet — Best needs the scan to know which frames are alike."
        }
        return "\(pending) of \(folderPhotos.count) still to measure — "
            + "Best shows unmeasured frames until the scan reaches them."
    }

    var sharpestOfSimilarRuns: Set<URL> {
        let chronological = PhotoOrder.sorted(folderPhotos, by: .captureTime,
                                              captureDates: captureIndex.dates)
        let frames = chronological.compactMap { url -> PhotoTriage.Frame? in
            guard let signature = triage[url]?.signature else { return nil }
            return PhotoTriage.Frame(url: url, signature: signature, captured: captureIndex.dates[url])
        }
        var picks = Set(chronological.filter { triage[$0] == nil })
        for run in PhotoTriage.groups(frames) {
            if let best = sharpestFrame(in: run) { picks.insert(best) }
        }
        return picks
    }

    /// A frame's focus reading from wherever it exists.
    ///
    /// There are two sources and they are not redundant: `focus` is filled for the photograph being
    /// opened (which may never have been scanned), and the shoot scan fills it from each verdict —
    /// but the verdict is the durable record and `focus` is a cache of one field of it. Reading
    /// through both means a sharpness question can never be answered "unmeasured" for a frame the
    /// scan has plainly measured, which is the shape of bug that comes from two dictionaries that
    /// are supposed to agree.
    func focusReading(_ url: URL) -> FocusMeasure.Reading? {
        focus[url] ?? triage[url]?.focus
    }

    /// The sharpest of a run, or its first frame when nothing in it could be measured.
    ///
    /// Ties go to the EARLIER frame: two frames of one pose can measure identically to the last
    /// decimal, and `max(by:)` would otherwise pick whichever the array order happens to put last —
    /// so the mark, and now the filter, would move about between renders for no reason the
    /// photographer can see.
    private func sharpestFrame(in urls: [URL]) -> URL? {
        let measured = urls.compactMap { url -> (URL, Double)? in
            guard let reading = focusReading(url), reading.measurable else { return nil }
            return (url, reading.acuity)
        }
        guard let best = measured.max(by: { $0.1 < $1.1 }) else { return urls.first }
        return measured.first(where: { $0.1 == best.1 })?.0 ?? best.0
    }

    // MARK: Grouping — how the strip is partitioned
    //
    // ONE control, ONE axis. Two passes in Core partition a shoot and they are complementary rather
    // than competing: `PhotoOrder.grouped` by when and where (day / burst / place, from one EXIF
    // header read), `PhotoTriage.groups` by what the picture looks like (a 64-bit difference hash
    // plus a time signal, from the triage scan).
    //
    // Surfacing both as separate menus would be worse than either. "How is the strip organised" is
    // ONE question, and a photographer who has picked "by day" and then meets a second, orthogonal
    // grouping control has to hold two partitions in their head to predict what they will see. So
    // similarity is a PEER of the metadata lenses — None / Burst / Day / Place / Similar — and not a
    // second dimension over them. See docs/DECISIONS.md, D-browse-1, including why the nested
    // version was rejected despite being strictly more expressive.

    /// The lens the strip is read through.
    enum StripGrouping: String, CaseIterable, Hashable {
        case none, burst, day, place, similar

        /// Short, for the control's own label.
        var label: String {
            switch self {
            case .none:    return "None"
            case .burst:   return "Burst"
            case .day:     return "Day"
            case .place:   return "Place"
            case .similar: return "Similar"
            }
        }

        /// Spelled out, for the menu — where there is room to say what the lens actually does.
        var longLabel: String {
            switch self {
            case .none:    return "No grouping"
            case .burst:   return "Bursts"
            case .day:     return "Capture day"
            case .place:   return "Place"
            case .similar: return "Similar pictures"
            }
        }

        /// The Core lens, where there is one. `nil` for the two cases Core does not own: no grouping
        /// at all, and similarity — which comes from the triage scan rather than the EXIF index.
        var coreKey: PhotoOrder.PhotoGroupKey? {
            switch self {
            case .burst:   return .burst
            case .day:     return .day
            case .place:   return .location
            case .none, .similar: return nil
            }
        }
    }

    var stripGrouping: StripGrouping = .none {
        didSet {
            // Similarity needs fingerprints, and the fingerprints come out of the scan the "Check
            // focus" button already runs — one pass, one 1200 px proxy per frame, both readings.
            // So asking for the lens IS asking for the measurement. The alternative is a menu item
            // that appears to do nothing on any folder nobody happens to have scanned yet, which is
            // indistinguishable from a broken control. Idempotent, and a no-op once the folder is
            // measured.
            if stripGrouping == .similar { scanFocus() }
        }
    }

    /// Whether grouping by place can say anything. False for most folders — a camera without GPS
    /// records no position at all — and false while the header read is still in flight, when the
    /// honest answer is "not yet" rather than "everything is in one place".
    var canGroupByPlace: Bool { captureIndex.hasAnyLocation }

    /// A run of the strip drawn under one heading.
    struct StripGroup: Identifiable, Equatable {
        let id: String
        /// `nil` draws no heading. A lone frame is not a burst and not a cluster of alike pictures,
        /// and heading every singleton would bury the runs that ARE one under a row of labels. Day
        /// and Place always have one: a day with a single frame in it is still that day.
        let heading: String?
        /// The second line — a count, a time span, a position. Never load-bearing on its own.
        let detail: String?
        let urls: [URL]
    }

    /// `visiblePhotos`, partitioned by the current lens.
    ///
    /// `nil` under `.none`, deliberately: a flat strip is a different rendering, not a grouping with
    /// one bucket — the same reason `PhotoGroupKey` carries no `.none` case. Modelling it as one
    /// bucket would make the view unwrap a heading it must not draw.
    var stripGroups: [StripGroup]? {
        guard stripGrouping != .none else { return nil }
        let photos = visiblePhotos
        guard !photos.isEmpty else { return [] }

        if stripGrouping == .similar { return similarGroups(photos) }
        guard let key = stripGrouping.coreKey else { return nil }
        // Groups and their members arrive in FINAL order — residue last, the strip's reverse already
        // applied. Do not re-sort them here.
        return PhotoOrder.grouped(photos, by: key, index: captureIndex,
                                  reversed: photoSortReversed)
            .map { group in
                StripGroup(id: group.id,
                           heading: heading(for: group),
                           detail: detail(for: group),
                           urls: group.urls)
            }
    }

    /// Near-duplicates, from the fingerprints the scan produced.
    ///
    /// Unmeasured frames are a residue group at the end rather than singletons scattered through the
    /// strip, because "no fingerprint yet" is not the same claim as "this picture is unique" and the
    /// two must not read alike. The group empties itself as the scan lands.
    private func similarGroups(_ photos: [URL]) -> [StripGroup] {
        // In CAPTURE order, not strip order: `PhotoTriage.groups` is order-dependent by construction
        // — a different order seeds different groups — and it documents capture order as its
        // contract, because that makes the seed the first frame of a burst and it is what the time
        // half of its rule assumes. Reversing the strip must change the order runs are SHOWN in,
        // never which frames are in a run together.
        let chronological = PhotoOrder.sorted(photos, by: .captureTime, captureDates: captureIndex.dates)
        let frames = chronological.compactMap { url -> PhotoTriage.Frame? in
            guard let signature = triage[url]?.signature else { return nil }
            return PhotoTriage.Frame(url: url, signature: signature, captured: captureIndex.dates[url])
        }
        let unmeasured = chronological.filter { triage[$0] == nil }

        var groups = PhotoTriage.groups(frames).map { urls in
            StripGroup(id: "similar:\(urls.first?.path ?? "")",
                       heading: urls.count > 1 ? "\(urls.count) alike" : nil,
                       detail: nil,
                       urls: urls)
        }
        if photoSortReversed { groups.reverse() }
        if !unmeasured.isEmpty {
            groups.append(StripGroup(id: "similar:unmeasured",
                                     heading: "Not measured yet",
                                     detail: "\(unmeasured.count) \(unmeasured.count == 1 ? "frame" : "frames")",
                                     urls: unmeasured))
        }
        return groups
    }

    /// Headings are the app's to format — Core does no localisation on purpose.
    private func heading(for group: PhotoOrder.PhotoGroup) -> String? {
        if group.isResidue {
            switch group.kind {
            case .day, .burst: return "No date"
            case .location:    return "No location"
            }
        }
        switch group.kind {
        case .day:
            guard let start = group.start else { return nil }
            return DateFormatter.localizedString(from: start, dateStyle: .full, timeStyle: .none)
        case .burst:
            // A run of one is not a burst. Saying so for every unrepeated frame in a shoot would be
            // several hundred headings, and the runs worth seeing would be lost among them.
            guard group.count > 1, let start = group.start else { return nil }
            return Self.timeOfDay.string(from: start)
        case .location:
            guard let anchor = group.anchor else { return nil }
            // A place name when one is known, degrees otherwise.
            //
            // This used to read "Coordinates, not a place name. Reverse geocoding is a network call,
            // and this app does not make network calls." That was reversed deliberately (D14): the
            // promise Kelvin makes is that your PHOTOGRAPHS are processed here rather than uploaded
            // to be processed, and a rounded coordinate exchanged for a town name is not that. It is
            // a switch in Settings, on by default, and `PlaceNames` is inert when it is off.
            //
            // Degrees remain the fallback and always will: the lookup is asynchronous, it can fail,
            // and a heading that goes blank waiting for the network would be worse than one that
            // reads in degrees. One decimal place is about 11 km — enough to tell two venues apart
            // without pretending to a precision the heading is not for.
            if let name = PlaceNames.shared.cachedName(for: anchor) { return name }
            return Self.coordinates(anchor)
        }
    }

    private func detail(for group: PhotoOrder.PhotoGroup) -> String? {
        let frames = "\(group.count) \(group.count == 1 ? "frame" : "frames")"
        guard !group.isResidue else { return frames }
        switch group.kind {
        case .day, .location:
            return frames
        case .burst:
            guard group.count > 1 else { return nil }
            // The span, so a six-frame run over two seconds reads differently from one over a
            // minute. Whole seconds: EXIF records the shutter to the second, so a decimal here
            // would be inventing resolution the file does not have.
            guard let duration = group.duration, duration >= 1 else { return frames }
            return "\(frames) · \(Int(duration.rounded()))s"
        }
    }

    /// Shared, because a `DateFormatter` is expensive to build and these are formatted per heading
    /// during view layout.
    private static let timeOfDay: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// "50.4°N, 4.1°W" — hemisphere letters rather than signs, which is how a position is read.
    static func coordinates(_ point: GeoPoint) -> String {
        let lat = String(format: "%.1f°%@", abs(point.latitude), point.latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.1f°%@", abs(point.longitude), point.longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }

    // MARK: Focus review
    //
    // Soft frames are SURFACED, never acted on. The measurement is good but not infallible, and an
    // automatic reject would quietly bin a frame you would have kept while hiding the evidence
    // that it got it wrong. Flagging for review keeps a false positive visible and one keystroke
    // from being corrected — which is also the only way the thresholds ever get better.

    /// Acuity per photo, filled in by the scan. Absent = not yet measured, which is distinct from
    /// measured-and-fine and is why this is not a Set.
    var focus: [URL: FocusMeasure.Reading] = [:]
    var focusScanProgress: Double?      // nil = not scanning
    /// The scan's time remaining, already phrased ("about 2 minutes left"). nil until the pace
    /// is measurable, and always nil when `focusScanProgress` is. See `ProgressETA`.
    var focusScanETA: String?

    /// What a scan concluded about each frame, beyond sharpness.
    ///
    /// Read in the SAME pass as focus rather than a second one. Both want the same 1200 px proxy,
    /// and that proxy is the dominant cost of the pass — an embedded-preview read on the fast
    /// path, a full RAW decode on the fallback. Scanning twice would pay it twice for a
    /// measurement that adds 2 ms.
    ///
    /// Deliberately NOT wired to any filter that hides frames. The concerns are advisory: the rule
    /// from the culling work is that photos are flagged for review, never auto-rejected, "so you
    /// can discover false positives" — and the pass that produces these deleted four of its own
    /// seven proposed verdicts after they fired on perfectly good photographs.
    ///
    /// This was declared, published, and never written to: the scan called a focus-only helper, so
    /// every verdict Core had been taught to produce was discarded before it reached the window.
    /// Nothing read the dictionary either, so it cost nothing and did nothing — the same shape as
    /// the dead `onFlag` the audit found, and it is why the near-duplicate grouping had no
    /// fingerprints to group on.
    var triage: [URL: PhotoTriage.Verdict] = [:]

    var softCount: Int { folderPhotos.filter { focus[$0]?.isSoft == true }.count }

    // MARK: What a photograph is, in words, for VoiceOver
    //
    // The app had no accessibility labels at all — every thumbnail and the canvas itself announced
    // as an unlabelled image — while generating an accurate one-sentence description of every
    // photograph and showing it only to people who can see it. A photo editor will never be fully
    // usable without sight, but "Backlit portrait against a bright window, subject in shadow" is a
    // great deal better than "image", and the text already exists and is now cached per photo.

    /// One frame, spoken. Filename first because that is its identity, then the reading, then the
    /// decisions someone has already made about it.
    ///
    /// Order matters: VoiceOver users hear this while arrowing through a shoot, so the thing that
    /// distinguishes one frame from the next has to come before the things most frames share.
    func spokenDescription(for url: URL) -> String {
        var parts = [url.lastPathComponent]
        if let note = cachedReading(for: url), !note.isEmpty {
            parts.append(note)
        }
        switch flags[url] {
        case .keep:   parts.append("flagged Keep")
        case .reject: parts.append("flagged Reject")
        case nil:     break
        }
        if editedURLs.contains(url) { parts.append("edited") }
        // The scan's findings, in the words it already uses for the tooltip — an automatic judgement
        // that is visible to sighted users and silent to everyone else is half a feature.
        if let verdict = triage[url], !verdict.concerns.isEmpty {
            parts.append(verdict.concerns.map(\.message).joined(separator: ", "))
        }
        return parts.joined(separator: ". ")
    }

    /// The model's sentence for a frame, from memory or from the cache on disk — without decoding
    /// anything. Nil for a frame nobody has read yet, which is the honest answer rather than a
    /// guess.
    func cachedReading(for url: URL) -> String? {
        if url == imageURL, let note = perception?.notes { return note }
        // IN MEMORY, NOT ON DISK. This is read by every filmstrip cell's accessibility label on every
        // evaluation of the strip — and the strip evaluates often. `PerceptionStore.load` is a file
        // open and a JSON decode; a profile of a slider drag found 11% of main-thread time here,
        // reading the same 437 sentences again and again. Misses are remembered too (`.some(nil)`),
        // or an unread shoot would stat every frame every pass until the model caught up.
        if let known = readingNotes[url] { return known }
        let note = PerceptionStore.load(for: url, modelId: perceptionProvider.activeModelID)?.notes
        readingNotes[url] = .some(note)
        return note
    }

    /// `cachedReading`'s memo. Filled on first ask and whenever a read lands (`rememberPerception`,
    /// the read-ahead loop), so a frame's sentence appears in the strip as soon as it exists.
    @ObservationIgnored private var readingNotes: [URL: String?] = [:]

    /// Did the scan notice anything at all about this frame — sharpness or exposure.
    ///
    /// Deliberately a union rather than "has an exposure concern": someone reviewing what the scan
    /// found wants all of it in one pass, and a filter that silently omitted the soft frames would
    /// be the more surprising of the two possible wrong answers.
    func isFlaggedByScan(_ url: URL) -> Bool {
        if focus[url]?.isSoft == true { return true }
        return triage[url]?.concerns.isEmpty == false
    }

    /// How many frames the scan flagged, for the filter chip's count.
    var flaggedCount: Int { folderPhotos.filter { isFlaggedByScan($0) }.count }

    /// What else the scan noticed about a frame, beyond sharpness: a frame so dark or so bright that
    /// most of it carries no detail. Focus concerns are excluded because the soft badge and the Focus
    /// filter already say that, and saying it twice in two glyphs on one thumbnail is noise.
    ///
    /// These fire on almost nothing by design — every threshold sits past the most extreme frame in
    /// 836 of the owner's real photographs — so a badge here means something unusual, which is
    /// exactly what makes it worth drawing.
    func exposureConcerns(for url: URL) -> [PhotoTriage.Concern] {
        (triage[url]?.concerns ?? []).filter { $0 != .softFocus && $0 != .outOfFocus }
    }

    /// The scan's findings for one frame, in words, for the strip's tooltip. The measurement travels
    /// with the flag on purpose: an automatic judgement you cannot see the number behind is one you
    /// can neither trust nor argue with.
    func scanNote(for url: URL) -> String? {
        guard let verdict = triage[url] else { return nil }
        var parts: [String] = []
        if verdict.focus.measurable {
            parts.append(String(format: "acuity %.1f", verdict.focus.acuity))
        }
        parts.append(contentsOf: verdict.concerns.map(\.message))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The sharpest frame of each run the strip is currently showing, where the run has more than one
    /// frame in it.
    ///
    /// This is the whole point of paying for the scan. Culling a burst is one question — "which of
    /// these six is the one" — and sharpness is the part of that question a machine can answer, on a
    /// measurement already taken. It stays a MARKER: nothing is flagged, hidden or rejected on the
    /// strength of it, because the sharpest frame of a run is not always the keeper (the one where
    /// the subject's eyes are open usually beats it) and a pass that decided for you would be wrong
    /// in exactly the cases you care most about.
    ///
    /// Only under Burst and Similar. Under Day or Place a "sharpest" is the sharpest frame of a whole
    /// afternoon, which answers no question anyone was asking.
    var sharpestInRun: Set<URL> {
        guard stripGrouping == .burst || stripGrouping == .similar,
              let groups = stripGroups else { return [] }
        var picks: Set<URL> = []
        for group in groups where group.urls.count > 1 {
            // At least two of the run must have been measurable, or "sharpest" is a claim about one
            // reading and a shrug. Shared tie-break with the `Best` filter — see `sharpestFrame` —
            // so the frame the marker points at is always the frame the filter keeps.
            let measurable = group.urls.filter { focusReading($0)?.measurable == true }
            guard measurable.count > 1, let best = sharpestFrame(in: group.urls) else { continue }
            picks.insert(best)
        }
        return picks
    }

    /// The scan, held so leaving the folder can stop it. See `scanFocus` for why that matters.
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Which scan is CURRENT. A cancelled scan's task group can take seconds to drain its
    /// in-flight decodes, and its trailing flush and epilogue run after that — by which time the
    /// next folder's scan may own the dictionaries and the progress flag. Bumped on every start
    /// and every external cancel; a task whose captured epoch no longer matches publishes nothing.
    @ObservationIgnored private var scanEpoch = 0

    /// Measure every frame in the folder, newest results published as they arrive so the strip
    /// fills in progressively rather than freezing until the end.
    func scanFocus() {
        guard focusScanProgress == nil else { return }      // already running
        let photos = folderPhotos
        guard !photos.isEmpty else { return }
        focusScanProgress = 0

        // Only the ones not already read — the scan used to walk every frame in the folder and skip
        // them one at a time, which made the progress bar lie about how much work was left.
        //
        // Keyed on the VERDICT, not on `focus`. Opening a photograph measures its focus as part of
        // the edit path, and that path produces no fingerprint — so skipping frames that merely have
        // a focus reading would leave whichever frames you had opened with no signature, and the
        // near-duplicate grouping silently missing exactly the pictures you had been working on.
        let pending = photos.filter { triage[$0] == nil }
        guard !pending.isEmpty else { focusScanProgress = nil; return }

        // HELD AND CANCELLABLE, because this pass can still be minutes long and it was neither.
        //
        // The costs have fallen twice since that bit: the fast path now reads a RAW's embedded
        // preview instead of paying ~1170 ms of full decode per frame (8½ minutes across a
        // 437-frame folder, which is where these rules were learned), and a verdict measured once
        // is now served from `MediaCache` on every later visit for the price of a `stat`. What
        // remains slow is the cold fallback — a body that embeds no usable preview still pays the
        // full decode — so the rules stay. Nothing stored the task and nothing cancelled it, so
        // leaving for another folder left all of it running — four cores decoding frames nobody is
        // looking at, each in-flight task holding a 1200 px proxy. Worse, `focusScanProgress` is
        // the re-entry guard, so the new folder's scan (and the Similar lens, which asks for one)
        // silently did nothing until the abandoned one drained.
        scanTask?.cancel()
        scanEpoch += 1
        let epoch = scanEpoch
        scanTask = Task { [weak self] in
            var done = 0
            // Fed per COMPLETION, below, not per flush — the batching of publishes is a SwiftUI
            // economy and must not become the clock the rate is measured with.
            var eta = ProgressETA()
            // SEVERAL AT ONCE. This was one photo at a time, and on a folder of large frames that
            // is minutes: the cost is dominated by decoding, and decoding one file leaves nine
            // cores idle.
            //
            // Safe to parallelise where the measurement passes on a single photo were not:
            // `FocusMeasure` is a Laplacian and a gradient, with no Vision anywhere in it. Vision
            // is the framework that crashes when two of its requests race, and none of this
            // touches it.
            //
            // Bounded rather than unbounded, but the bound is looser than it was, because the cost
            // it was protecting against has largely gone. It used to be 4 because each task could
            // hold a fully decoded 60 MP frame; `PerceptionProxy.measurementProxy` now reads a RAW
            // file's embedded preview, so a task in flight holds a few megabytes rather than a few
            // hundred. What remains is the FALLBACK — a body that embeds no usable preview still
            // pays for a real decode — so this stays bounded rather than becoming `cores`.
            let limit = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
            await withTaskGroup(of: (URL, PhotoTriage.Verdict?).self) { group in
                var next = 0
                func start() {
                    guard next < pending.count else { return }
                    let url = pending[next]; next += 1
                    // .userInitiated: somebody pressed a button and is watching a progress bar.
                    //
                    // Through the disk cache: a verdict is a pure function of the file's bytes and
                    // the measurement geometry, both of which are in the cache key, so a shoot
                    // measured once costs one `stat` per frame on every later visit. A miss
                    // measures via `PhotoTriage.read` and writes through. Either way the result
                    // lands below exactly as a fresh measurement would — `triage` AND `focus`.
                    group.addTask(priority: .userInitiated) {
                        // The decode is on the scan lane, not on this pool thread: the group only
                        // bounds how many are asked for at once, Offload is what keeps them off
                        // the cooperative pool while they run.
                        (url, await Offload.run(.scan) { MediaCache.shared.verdict(for: url) })
                    }
                }
                for _ in 0..<min(limit, pending.count) { start() }

                // Published in BATCHES, not per completion. Every arriving frame used to publish
                // three times — `triage`, `focus`, progress — and with the `Best` filter active
                // each publish re-evaluates `visiblePhotos`, which sorts and regroups the whole
                // shoot; the Similar lens pays for `stripGroups` again on top. On a 437-frame
                // folder that is ~1300 SwiftUI invalidations each dragging an O(n log n) pass
                // across the main thread while the scan is trying to use it. Eight completions
                // per flush is one strip window's worth: the strip still fills in visibly, at a
                // fraction of the invalidations.
                let flushEvery = 8
                var batch: [(URL, PhotoTriage.Verdict)] = []
                @MainActor func flush(into state: AppState) {
                    for (url, verdict) in batch {
                        state.triage[url] = verdict
                        // The focus reading rides INSIDE the verdict — same 1200 px proxy, same
                        // `FocusMeasure.read`. Published separately as well because `softCount`,
                        // the Focus filter and the strip's soft badge all key off this dictionary,
                        // and a measurement moving house is not a reason to make three working
                        // things reach through a verdict for it.
                        state.focus[url] = verdict.focus
                    }
                    batch.removeAll(keepingCapacity: true)
                    state.focusScanProgress = Double(done) / Double(pending.count)
                    state.focusScanETA = eta.phrase(itemsLeft: pending.count - done)
                }

                for await (url, verdict) in group {
                    guard let self else { return }
                    // Cancellation is checked where the work is HANDED OUT as well as where it
                    // lands: `group.cancelAll()` stops the queue from issuing more decodes, which is
                    // the expensive half. The already-measured frames are kept — a verdict is a
                    // verdict whether or not you stayed to watch it arrive — which is why the
                    // trailing flush below runs on this path too.
                    if Task.isCancelled { group.cancelAll(); break }
                    if let verdict { batch.append((url, verdict)) }
                    done += 1
                    eta.recordCompletion()
                    if done % flushEvery == 0 { flush(into: self) }
                    start()          // keep `limit` in flight until the queue is empty
                }
                // The final partial batch: the last `pending.count % flushEvery` frames on a
                // normal finish, or whatever had already landed when the scan was cancelled —
                // but ONLY while this scan is still the current one. A cancelled scan's group can
                // take seconds to drain its in-flight decodes, and by then the next folder's scan
                // may own the dictionaries: an audit found this trailing flush re-publishing the
                // OLD folder's just-evicted triage entries over the new folder's, and the
                // epilogue below nil-ing the NEW scan's progress — which is also the re-entry
                // guard, so a third call in that window would have started a second concurrent
                // scan. The epoch is bumped on every start and every external cancel.
                if let self, self.scanEpoch == epoch { flush(into: self) }
            }
            guard let self, self.scanEpoch == epoch else { return }
            self.focusScanProgress = nil
            self.focusScanETA = nil
        }
    }

    // `readFocus` lived here and is gone: `PhotoTriage.read(url:)` does the same proxy-first decode
    // (ImageIO's decode-to-size where there is one, a real decode for RAW, materialised once) and
    // returns the focus reading inside a verdict. Two copies of the scan's decode path is how the
    // 1200 px proxy the soft/unusable thresholds were calibrated against quietly becomes two
    // different proxies.

    // MARK: What leaves the app

    /// Whether an export takes the photograph's position and the camera body's serial out with it.
    ///
    /// OFF by default, which is the owner's call and matches every other editor: metadata travelling
    /// with a photograph is the convention, and a photographer exporting for a client usually wants
    /// the camera, lens, date and exposure to survive. What was missing was any way to say no — the
    /// GPS fix and `BodySerialNumber` were re-encoded into every export and every batch frame, with
    /// nothing anywhere saying so.
    ///
    /// Persisted, because it is a property of how you work rather than of one export. A photographer
    /// who strips location does it every time, and asking them to remember a checkbox per file is how
    /// the one that matters gets missed.
    var stripLocationOnExport = UserDefaults.standard.bool(forKey: AppState.stripLocationKey) {
        didSet { UserDefaults.standard.set(stripLocationOnExport, forKey: AppState.stripLocationKey) }
    }
    static let stripLocationKey = "export.stripLocation"

    /// Whether the file handed to the share sheet carries the photograph's position.
    ///
    /// Deliberately NOT persisted, unlike `stripLocationOnExport`, and the polarity is reversed:
    /// off is the default and off means stripped. A remembered "include" from last month's hike
    /// is how a home address rides into a stranger's Messages thread — the rare cost here is
    /// re-ticking a box, the rare cost there is a leak, so the box resets. Same reasoning as
    /// `exportLabel`.
    var shareIncludeLocation = false
    /// The photograph whose share render is (or was last) in the picker — what
    /// `SharePresenter.onDidChoose` checks before logging the pick. Not published; nothing draws it.
    @ObservationIgnored var pendingSharePickURL: URL?

    /// True from share press to file-on-disk — the Share button's re-entry guard and spinner.
    /// Separate from `isProcessing`, which belongs to the status line and is set by half a dozen
    /// longer flows; a share must not un-busy an export or vice versa.
    var isPreparingShare = false

    // The rest of the export configuration. Persisted for the same reason: a photographer who
    // exports 2048 px sRGB JPEGs for a gallery does it every time, and re-choosing it per file is
    // how the one that matters gets exported at the wrong size.
    var exportFormatId = UserDefaults.standard.string(forKey: "export.format") ?? "jpeg" {
        didSet { UserDefaults.standard.set(exportFormatId, forKey: "export.format") }
    }
    var exportQuality = UserDefaults.standard.object(forKey: "export.quality") as? Double ?? 0.97 {
        didSet { UserDefaults.standard.set(exportQuality, forKey: "export.quality") }
    }
    /// 0 means full resolution. Stored as a plain number so the setting survives a schema change.
    var exportLongEdge = UserDefaults.standard.object(forKey: "export.longEdge") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(exportLongEdge, forKey: "export.longEdge") }
    }
    var exportColorSpaceId = UserDefaults.standard.string(forKey: "export.colorSpace") ?? "sRGB" {
        didSet { UserDefaults.standard.set(exportColorSpaceId, forKey: "export.colorSpace") }
    }
    var exportNamingId = UserDefaults.standard.string(forKey: "export.naming") ?? "descriptive" {
        didSet { UserDefaults.standard.set(exportNamingId, forKey: "export.naming") }
    }

    var exportFormat: ImageWriter.Format {
        switch exportFormatId {
        case "png":    return .png
        case "tiff16": return .tiff16
        case "heic":   return .heic(quality: exportQuality)
        default:       return .jpeg(quality: exportQuality)
        }
    }
    var exportSize: ImageWriter.Size {
        exportLongEdge > 0 ? .longEdge(exportLongEdge) : .fullResolution
    }

    /// What the single-photo export button says it will do.
    ///
    /// **It used to be the hard-coded string "Export full-res" while the run honoured
    /// `exportLongEdge`, which is persisted** — so a photographer who once chose 2048 px got a
    /// 2048 px file, every time afterwards, from a button that promised full resolution, with
    /// nothing on screen to say otherwise. The button's name was a lie and the setting that made it
    /// one was invisible until the panel was already open. Now the label reads the setting.
    var exportOneButtonLabel: String {
        exportLongEdge > 0 ? "Export \(exportLongEdge) px" : "Export full-res"
    }

    var exportOneButtonHelp: String {
        exportLongEdge > 0
            ? "Render this photo with its long edge at \(exportLongEdge) px — the size you chose "
                + "last time. Change it under Size in the export panel."
            : "Render this photo at its full resolution."
    }
    var exportColorSpace: ImageWriter.ColorSpace {
        ImageWriter.ColorSpace(rawValue: exportColorSpaceId) ?? .sRGB
    }
    var exportNaming: ExportNaming.Scheme {
        ExportNaming.Scheme(rawValue: exportNamingId) ?? .descriptive
    }

    /// The photographer's own word for this export — a place, a client, an event.
    ///
    /// **Deliberately not persisted, and cleared when the shoot changes.** Every other export
    /// setting here is a statement about how someone works and is remembered; this one is a
    /// statement about *this shoot*, and a remembered "Tuscany" is how a Reykjavik wedding gets
    /// delivered labelled Tuscany. Same reasoning as `exportKeepersOnly`, with a worse failure:
    /// that one exports the wrong count, this one puts the wrong word on a client's files.
    var exportLabel = ""

    /// A word pinned to the FRONT of every exported name, and one pinned to the END.
    ///
    /// **Remembered.** These were deliberately not persisted, on the same reasoning as
    /// `exportLabel` — a remembered affix delivers next month's wedding under last month's client
    /// name. The owner reported the loss as a bug, and on reflection the reasoning was right about
    /// the label and wrong about these: `v2`, `-edited`, a studio's standing prefix are *habits*,
    /// which is exactly the test the scheme above is already remembered by. Retyping a habit before
    /// every export is a tax paid every time to prevent a mistake that is rare.
    ///
    /// The dangerous case is handled better by SHOWING than by forgetting. Both fields are built
    /// pre-filled from these values and sit directly above a live example of the resulting filename
    /// (`refreshNamingExample`), so a stale prefix is on screen, spelled out, before anything is
    /// written. Forgetting hid the setting; remembering it and printing it does not.
    ///
    /// `exportLabel` stays per-shoot. It is the one that is a statement about *this* job by
    /// definition, and it is already cleared when the shoot changes.
    var exportPrefix = UserDefaults.standard.string(forKey: "export.prefix") ?? "" {
        didSet { UserDefaults.standard.set(exportPrefix, forKey: "export.prefix") }
    }
    var exportSuffix = UserDefaults.standard.string(forKey: "export.suffix") ?? "" {
        didSet { UserDefaults.standard.set(exportSuffix, forKey: "export.suffix") }
    }

    /// What the label will actually look like in a filename, or nil when there is nothing to show.
    /// The panel prints this, because the sanitiser lowercases and hyphenates and nobody should
    /// have to discover that after the files are written.
    var exportLabelPreview: String? {
        let clean = ExportNaming.labelToken(exportLabel)
        return clean.isEmpty ? nil : clean
    }

    var exportMetadata: ImageWriter.MetadataPolicy {
        stripLocationOnExport ? .withoutLocation : .asShot
    }

    /// Whether opening ONE photograph also lists the rest of its folder in the strip.
    ///
    /// On by default, because a shoot is the unit of work here — culling, batch apply and the arrow
    /// keys all operate on the strip, and an editor that opens exactly one file makes all three
    /// useless. But it was never stated anywhere, so opening a single frame and watching a folder
    /// appear read as the app doing something it had not been asked to do. Reported exactly that way.
    ///
    /// Now it is a choice, surfaced in the Open panel and remembered. Applies to drops as well as the
    /// panel: it is a statement about how someone works, not about one gesture.
    ///
    /// Note this only governs LISTING. Nothing in the folder is read — no EXIF, no sidecars, no
    /// thumbnails — until the strip is unfolded; see `loadFolderDetailIfVisible`.
    var includeFolderOnOpen = UserDefaults.standard.object(forKey: AppState.includeFolderKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeFolderOnOpen, forKey: AppState.includeFolderKey) }
    }
    static let includeFolderKey = "open.includeFolder"

    /// Not persisted, on purpose: which photos to export is a per-shoot decision, and a remembered
    /// "kept only" from last week is how someone exports three photos and believes they exported
    /// thirty.
    var exportKeepersOnly = false

    /// The photos an "Export edited" run will write, in filmstrip order. Pure and separated from
    /// the export loop so the rule is testable without rendering anything.
    ///
    /// A frame qualifies two ways, and the second is what makes shoot looks mean anything: it
    /// carries a hand-made edit, OR the shoot's look claims it. Before, applying a look to four
    /// hundred frames and pressing Export wrote only the handful you had also touched by hand —
    /// which is the feature appearing to do nothing.
    func exportTargets(keepersOnly: Bool) -> [URL] {
        folderPhotos.filter { url in
            (editedURLs.contains(url) || effectiveStyle(for: url) != nil)
                && (!keepersOnly || flags[url] == .keep)
        }
    }

    /// How many frames an export would write — hand-edited or claimed by the shoot's look. Drives
    /// the button's label so it says what it will do.
    var exportableCount: Int { exportTargets(keepersOnly: false).count }

    /// What the group export will actually write, in filmstrip order.
    ///
    /// **A selection is the scope**, exactly as it already is for `Apply to shoot` (`applyScope`) —
    /// export was the one action in the app that ignored the selection entirely, so "export these
    /// four" meant selecting four frames, watching the button carry on saying 126, and having no
    /// way to say it. Note the deliberate difference from `exportTargets`: a selected frame is
    /// exported whether or not it carries an edit, because pointing at a frame and asking for it IS
    /// the request. Requiring an edit as well would silently drop frames the photographer had just
    /// picked by hand, which is the failure that is impossible to see in a folder of results.
    func exportScope() -> [URL] {
        guard selectedPhotos.isEmpty else {
            return folderPhotos.filter { selectedPhotos.contains($0) }
        }
        return exportTargets(keepersOnly: exportKeepersOnly)
    }

    /// What the group export button says it will do — a SCOPE and a count, not a bare number.
    ///
    /// It used to read "Export 40", which names neither what those 40 are nor the fact that the
    /// panel's Kept-only checkbox could narrow them: the count came from `exportableCount`, which
    /// ignores `exportKeepersOnly`, so the button could promise 40 and write 12. Now the number is
    /// the scope's own count and the word beside it says which scope produced it.
    var exportButtonLabel: String {
        if !selectedPhotos.isEmpty { return "Export \(selectedPhotos.count) selected" }
        return "Export \(exportScope().count) edited"
    }

    /// What the export button promises. It splits the count because the two halves cost wildly
    /// different amounts of time: a hand-made edit renders from a stored recipe in a moment, while a
    /// frame carried by the shoot's look has to be read and measured first. Someone about to export
    /// four hundred adapted frames should know that before they press it, not while they wait.
    var exportEditedHelp: String {
        if !selectedPhotos.isEmpty {
            let n = selectedPhotos.count
            return "Render the \(n) frame\(n == 1 ? "" : "s") you have selected, edited or not. "
                + "Clear the selection to export everything this shoot's look claims."
        }
        let targets = exportTargets(keepersOnly: exportKeepersOnly)
        let byHand = targets.filter { editedURLs.contains($0) }.count
        let byLook = targets.count - byHand
        if byLook == 0 {
            return "Render every photo you have edited in this shoot, each with its own edit"
        }
        if byHand == 0 {
            return "Render \(byLook) photo\(byLook == 1 ? "" : "s") in the shoot's look — each one is "
                + "read and adapted to its own frame, so this takes a few seconds per photo"
        }
        return "Render \(byHand) hand-edited photo\(byHand == 1 ? "" : "s") plus \(byLook) in the "
            + "shoot's look. The adapted ones are read individually and take a few seconds each."
    }

    /// Same idea for Batch apply. Not persisted, same reason as `exportKeepersOnly`.
    var batchKeepersOnly = false

    /// The photos a batch run over the open shoot will adapt, in filmstrip order. An edit is not
    /// required — batch creates edits — so the only narrowing is the Keep flag when asked.
    func batchTargets(keepersOnly: Bool) -> [URL] {
        folderPhotos.filter { !keepersOnly || flags[$0] == .keep }
    }

    var keeperCount: Int { folderPhotos.filter { flags[$0] == .keep }.count }
    var rejectCount: Int { folderPhotos.filter { flags[$0] == .reject }.count }

    func setFlag(_ flag: PhotoFlag, for url: URL) {
        FlagStore.toggle(flag, for: url)
        flags[url] = FlagStore.flag(for: url)
    }

    /// Flag the open photo and step to the next one — the whole point of a cull pass is that one
    /// keystroke both decides and advances.
    func flagCurrentAndAdvance(_ flag: PhotoFlag) {
        guard let url = imageURL else { return }
        setFlag(flag, for: url)
        Task { await advance(by: 1) }
    }

    /// Move through the folder in the order the strip shows.
    func advance(by step: Int) async {
        let list = visiblePhotos
        guard let url = imageURL, let index = list.firstIndex(of: url), list.count > 1 else { return }
        let next = list[(index + step + list.count) % list.count]
        await openPhoto(next)
    }
    /// Frames dismissed from the strip this session. Held separately because opening any photo
    /// re-scans the folder — without this, a dismissed frame simply reappeared.
    @ObservationIgnored private var dismissedURLs: Set<URL> = []
    /// Full editing state per photo, so switching away and back is instant and lossless — no
    /// re-running the model. Bounded, because each entry pins decoded images.
    @ObservationIgnored var sessions: [URL: PhotoSession] = [:]
    @ObservationIgnored private var sessionOrder: [URL] = []
    private static let maxSessions = 8

    /// Put a mask measured on one image onto another's extent.
    ///
    /// Masks are decided at 768 px and drawn at 1200 px, and `CIBlendWithMask` needs the two to
    /// line up — a mask covering part of the image extent does not blend, it clips. Nothing real is
    /// lost in the scale: Vision hands back a fixed-size buffer whatever resolution it is given,
    /// and `SkyMask` classifies on a 160-px grid, so a mask has always been an upscale of something
    /// small. Returns the mask untouched when it is already the right size.
    /// `nonisolated` because it is pure — extent arithmetic and a transform, no state. The fine
    /// render calls it from a detached task (see `fineRender`), and the alternative to saying so is
    /// hopping to the main actor to scale a mask, which is the opposite of the point.
    nonisolated static func scaleMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let from = mask.extent
        guard !from.isInfinite, from.width > 0, from.height > 0,
              !extent.isInfinite, extent.width > 0, extent.height > 0,
              from.size != extent.size else { return mask }
        return mask
            .transformed(by: CGAffineTransform(scaleX: extent.width / from.width,
                                               y: extent.height / from.height))
            .transformed(by: CGAffineTransform(translationX: extent.origin.x - from.origin.x,
                                               y: extent.origin.y - from.origin.y))
            .cropped(to: extent)
    }

    /// Which photographs are currently held in the cache. Read-only on purpose — `openPhoto` and
    /// `stashCurrentSession` are the only things that may write it.
    var cachedSessionURLs: Set<URL> { Set(sessions.keys) }

    /// The cached frames an apply over `scope` has to throw away, so they are re-read against the
    /// look that was just applied rather than restored as they were under the old one.
    ///
    /// Pure over the keys it is handed, so the rule is checkable without decoding a photograph.
    /// Two frames are deliberately spared: the one whose pixels are loaded (the apply updates it in
    /// place, and re-reading it would throw away a decode someone is looking at), and anything
    /// carrying a hand edit, which outranks the shoot's look and is therefore unaffected by it.
    func staleSessionURLs(coveredBy scope: [URL], cached: Set<URL>) -> Set<URL> {
        let covered = Set(scope)
        return cached.filter { covered.contains($0) && $0 != loadedURL && !editedURLs.contains($0) }
    }
    private var thumbnails: [URL: NSImage] = [:]
    /// URLs whose thumbnail is being fetched, so a redrawn strip doesn't queue the same work twice.
    @ObservationIgnored private var thumbnailsInFlight: Set<URL> = []

    /// A filmstrip thumbnail, **never decoded on the calling thread**.
    ///
    /// This used to decode inline. Called from `FilmstripView.cell` during view-body evaluation,
    /// that put a full image decode on the main thread once per visible cell — and for a folder of
    /// 60 MP RAWs it meant dozens of full RAW decodes before SwiftUI could finish a single layout
    /// pass. The window could not draw at all, which read as "the app won't open my photos".
    ///
    /// Now: return whatever is cached, start a background fetch for anything missing, and publish
    /// it when it arrives. A cell with no thumbnail yet simply shows its placeholder.
    /// Decoded thumbnails waiting to be published, and the timer that publishes them together.
    ///
    /// `thumbnails` is `@Published`, so every arriving thumbnail used to be its own update of the
    /// whole view tree. Dragging the strip open by one row reveals a dozen cells at once, which
    /// meant a dozen full passes in the middle of a gesture — the "jumpy" in a jumpy resize — and
    /// scanning a shoot did the same thing hundreds of times over. Buffered and flushed together,
    /// a burst becomes one update.
    @ObservationIgnored private var thumbnailBuffer: [URL: NSImage] = [:]
    @ObservationIgnored private var thumbnailFlushScheduled = false

    private func scheduleThumbnailFlush() {
        guard !thumbnailFlushScheduled else { return }
        thumbnailFlushScheduled = true
        // Long enough to gather a burst, short enough that a thumbnail never looks slow to appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.thumbnailFlushScheduled = false
            guard !self.thumbnailBuffer.isEmpty else { return }
            self.thumbnails.merge(self.thumbnailBuffer) { _, new in new }   // one publish, not N
            self.thumbnailBuffer.removeAll()
        }
    }

    func thumbnail(for url: URL) -> NSImage? {
        // The buffer counts as a hit: a decoded thumbnail that has not been flushed yet must not
        // be decoded a second time, and must not be reported missing to a cell about to draw.
        if let hit = thumbnails[url] ?? thumbnailBuffer[url] { return hit }
        guard !thumbnailsInFlight.contains(url) else { return nil }
        thumbnailsInFlight.insert(url)
        Task { [weak self] in
            // Returns a CGImage rather than an NSImage: NSImage's Sendable conformance exists on
            // the macOS 27 SDK and is unavailable on the one CI builds against, so handing one out
            // of a detached task compiles here and fails there. CGImage is Sendable on both, and
            // the NSImage is wanted on the main actor anyway.
            let cg = await Offload.run(.thumbnail, qos: .utility) {
                PhotoBrowser.thumbnailCG(for: url)
            }
            let image = cg.map { NSImage(cgImage: $0, size: .zero) }
            guard let self else { return }
            self.thumbnailsInFlight.remove(url)
            if let image {
                self.thumbnailBuffer[url] = image
                self.scheduleThumbnailFlush()
            }
        }
        return nil
    }

    /// How many masks are actually doing something, for the folded section's badge. A collapsed
    /// section must still say whether there is anything inside it, or folding it away hides work.
    var maskCountLabel: String? {
        let active = baseMaskIds.filter { maskEnabled[$0] ?? true }.count + userMasks.count
        return active > 0 ? "\(active)" : nil
    }

    /// The filename Kelvin suggests for an export — built from what it understood about the
    /// photo, so a folder of exports is searchable instead of a wall of `kelvin-edit`.
    func suggestedExportName(ext: String = "jpg") -> String {
        guard let url = imageURL else { return "\(Branding.exportStem)." + ext }
        let look = activeLookId.flatMap { LookPreset.named($0)?.name }
            ?? candidates.first { $0.id == selectedCandidateId }?.label
        return ExportNaming.filename(for: url, perception: perception, look: look, ext: ext,
                                     scheme: exportNaming, label: exportLabel,
                                     prefix: exportPrefix, suffix: exportSuffix)
    }

    /// "12 Mar, 14:03" from an ISO timestamp — a restored edit should say *when*, not show a
    /// machine string.
    static func friendlyDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "an earlier session" }
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }

    // MARK: Reusing a read across near-duplicates
    //
    // A burst of twenty frames of one pose is one scene: same subject, same light, same problems.
    // Reading it twenty times costs twenty generations — measured at ~6.5 s each, and measured to be
    // dominated by writing the answer rather than by looking at the photograph, so a smaller image
    // would not have helped. Reading it once and reusing the answer costs one.
    //
    // THIS DOES NOT SHARE ANY NUMBERS. The model only ever returns categories — scene, subject,
    // lighting, what is technically wrong — and every actual parameter is computed per frame from
    // that frame's own histogram and EXIF. Sharing "backlit portrait, subject underexposed" across a
    // burst is sharing a true statement about all of them; the exposure each one gets is still its
    // own. Non-negotiable #1 is untouched.
    //
    // The fingerprint is the same 64-bit difference hash the Similar grouping uses, at the same
    // threshold, so "close enough to reuse" means exactly what "close enough to group" means — one
    // definition of near-duplicate in the app rather than two that can disagree.

    @ObservationIgnored private var perceptionBySignature: [(signature: PhotoTriage.Signature, perception: Perception)] = []
    private static let maxRememberedReads = 32

    /// The signature for `url`, from the scan if it has run, measured now if not. Cheap either way
    /// now that a RAW's embedded preview is enough to measure.
    /// The frame's difference-hash fingerprint, from the scan if it has already measured this one and
    /// from the file if not.
    ///
    /// **The read goes off the main actor and the proxy size does not change.** This ran on the main
    /// thread, twice per photograph opened — once to look for a reusable read and once to remember
    /// the new one — and `measurementProxy` is a file open and a decode. On a share that was two
    /// network decodes blocking the window per frame, which is most of what "non-responsive over my
    /// NAS" meant.
    ///
    /// Still `PerceptionProxy.measurementProxy` at `PhotoTriage.proxyEdge`, deliberately, even though
    /// `loadPhoto` has a 1200 px proxy of the same photograph sitting right there. They are not the
    /// same picture: for RAW, `measurementProxy` takes the camera's embedded preview while the edit
    /// proxy is Apple's real decode, and a difference hash over one does not match a difference hash
    /// over the other. The scan populates `triage` from `measurementProxy`, and these fingerprints are
    /// compared against each other, so switching source here would silently change which frames read
    /// as near-duplicates. Moving the call is the fix; changing what it measures is a different
    /// decision and not one to make by accident.
    private func signature(for url: URL) async -> PhotoTriage.Signature? {
        if let known = triage[url]?.signature { return known }
        return await Offload.run(.scan) {
            guard let proxy = PerceptionProxy.measurementProxy(url, maxEdge: PhotoTriage.proxyEdge)
            else { return nil }
            return PhotoTriage.signature(of: proxy)
        }
    }

    private func reusablePerception(for url: URL) async -> Perception? {
        guard let mine = await signature(for: url), mine.isMeasurable else { return nil }
        // An unmeasurable fingerprint means "no signal", not "unique" — never reuse against one.
        return perceptionBySignature.first {
            $0.signature.isMeasurable
                && $0.signature.distance(to: mine) <= PhotoTriage.nearDuplicateDistance
        }?.perception
    }

    private func rememberPerception(_ perception: Perception, for url: URL) async {
        readingNotes[url] = .some(perception.notes)
        guard let signature = await signature(for: url), signature.isMeasurable else { return }
        perceptionBySignature.append((signature, perception))
        if perceptionBySignature.count > Self.maxRememberedReads {
            perceptionBySignature.removeFirst()
        }
    }

    /// Load the perception model in the background at launch, so the first photograph does not pay
    /// for it. See `MLXPerceptionProvider.preload`.
    func warmPerception() async {
        await perceptionProvider.preload()
    }

    /// What the model said it saw, for the panel — the categorical read on one line, and its own
    /// sentence beneath.
    ///
    /// Deliberately not a confidence number. A model's stated confidence is the least reliable thing
    /// it produces, and putting 0.82 next to a description invites it to be read as a measurement
    /// when everything else on this screen genuinely is one.
    var sceneSummary: (headline: String, note: String?)? {
        guard let p = perception else { return nil }
        var parts: [String] = [p.scene.rawValue]
        if let light = ExportNaming.descriptor(for: p.lighting.condition) {
            parts.append(light.replacingOccurrences(of: "-", with: " "))
        }
        if p.subject.present, p.subject.type != .none {
            // The model's own name for the subject ("sea stack", "bride") reads better than the
            // category word — but it is free text, so it appears here on the SAME terms as
            // `notes`: display only, never something a decision branches on.
            parts.append(p.subject.label ?? p.subject.type.rawValue
                .replacingOccurrences(of: "-", with: " "))
        }
        if !p.problems.isEmpty {
            parts.append(p.problems.map(\.rawValue).joined(separator: ", "))
        }
        let note = p.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (parts.joined(separator: " · "), (note?.isEmpty == false) ? note : nil)
    }

    /// Whether any photograph has been read since launch. Only ever used to tell the truth about
    /// how long the first one takes.
    @ObservationIgnored private var hasReadAPhoto = false

    /// The current edit, in the form that goes to disk. Internal rather than private so the
    /// round-trip test can save exactly what the app saves.
    func currentSavedEdit() -> SavedEdit {
        SavedEdit(styleId: selectedCandidateId, global: edit, userMasks: userMasks,
                  maskEnabled: maskEnabled, maskStrength: maskStrength,
                  straighten: straighten, hsl: hsl, blackAndWhite: activeRecipe?.blackAndWhite,
                  lookId: activeLookId,
                  healSpots: healSpots.isEmpty ? nil : healSpots,
                  // The composed recipe, so this edit can be re-rendered without re-perceiving the
                  // photograph. See SavedEdit.recipe.
                  recipe: activeRecipe,
                  savedAt: ISO8601DateFormatter().string(from: Date()),
                  // Nil rather than "" when the background hash has not landed yet. `contentHint` is
                  // provenance and is explicitly not used for lookup, so an edit saved in the first
                  // moment after opening a large file simply records no hint — which is the same
                  // thing every sidecar written before the field existed records.
                  contentHint: imageId.isEmpty ? nil : imageId)
    }

    /// Write the edit for `url` if it differs from what Kelvin generated, or clear it if the user
    /// has reset back to the candidate — otherwise a stale file would keep resurrecting an edit
    /// they undid.
    private func persistEdit(for url: URL) {
        if isTouched { EditStore.save(currentSavedEdit(), for: url) }
        else { EditStore.remove(for: url) }
    }

    /// Has this photograph been edited at all — the ONE definition, used everywhere.
    ///
    /// This test existed in three places, written out longhand each time, and every copy omitted
    /// the same things: the mask panel's dictionaries and the active look. Two consequences, and
    /// the second is the bad one.
    ///
    /// Turn off the sky mask, or change its strength, or adjust it, and the photo did not count as
    /// edited — so no dot in the strip, and nothing saved. Then, because `persistEdit` takes the
    /// other branch when untouched, reverting the globals while KEEPING a mask change did not
    /// merely fail to save: it called `EditStore.remove` and deleted the sidecar that was already
    /// on disk.
    ///
    /// One property, so the next thing added to the edit surface has one place to be declared
    /// rather than three places to be forgotten.
    var isTouched: Bool {
        edit != editBaseline
            || !userMasks.isEmpty
            || straighten != 0
            || !hsl.isEmpty
            || !healSpots.isEmpty
            || activeLookId != nil
            || !maskAdjustments.isEmpty
            || !maskFeather.isEmpty
            || !maskTightness.isEmpty
            || !maskInvert.isEmpty
            // Explicitly-set enable/strength: a mask switched OFF is an edit, and an untouched
            // photo has no entries here at all.
            || !maskEnabled.isEmpty
            || !maskStrength.isEmpty
    }

    /// Restore a saved edit onto the freshly-generated candidates. Internal rather than private
    /// so the round-trip test can reopen exactly the way a new session does.
    func apply(_ saved: SavedEdit) {
        if let styleId = saved.styleId, candidates.contains(where: { $0.id == styleId }) {
            selectCandidate(id: styleId)      // sets the baseline for this style first
        }
        edit = saved.global
        userMasks = saved.userMasks
        rekeyInstanceMasks()
        maskEnabled = saved.maskEnabled
        maskStrength = saved.maskStrength
        straighten = saved.straighten
        hsl = saved.hsl
        // The look comes back BEFORE the recipe is rebuilt: `updateActiveRecipe` derives the
        // mono conversion and the look's curve from `activeLookId`, so restoring it after (or
        // never, which is what shipped) rebuilt the recipe with the conversion stripped — a
        // mono-looked photo reopened in colour, and the next save persisted the loss. The
        // globals need no such step; they were saved as absolutes and arrived with `edit` above.
        //
        // A sidecar from before `lookId` existed can still name its look: the only source of a
        // `blackAndWhite` mix IS a look, so the mix identifies it in the library.
        activeLookId = saved.lookId
            ?? saved.blackAndWhite.flatMap { mix in LookPreset.library.first { $0.mono == mix }?.id }
        healSpots = saved.healSpots ?? []
        brushCache = [:]
        updateActiveRecipe()
        resetHistory()
    }

    /// The photo whose decoded images are actually in memory right now.
    ///
    /// NOT the same thing as `imageURL`, and the difference is load-bearing. `imageURL` is what the
    /// app is *showing you*, and `loadPhoto` sets it the moment you pick a photo — seconds before
    /// the decode finishes. `loadedURL` is what is actually in `fullResCI`/`proxyCI`/`original`, and
    /// it only moves when a decode lands. Everything that files the current state away has to key
    /// on this one: keyed on `imageURL`, opening a third photo while the second was still decoding
    /// filed the FIRST photo's images, edit and sidecar under the SECOND photo's URL, and reopening
    /// that frame from the strip then showed someone else's picture.
    /// Internal, not private, so the photo-switch rules below can be pinned by test.
    @ObservationIgnored var loadedURL: URL?

    /// Whether the per-photo state has been torn down but `loadedURL` has not moved on yet.
    ///
    /// The window between `clearPerPhotoState` and the new decode landing is the one place where
    /// `loadedURL` describes a photograph the rest of the state no longer does — deliberately, so a
    /// failed load can be retried. Anything that FILES state away in that window would file an empty
    /// panel under the previous photograph: overwriting its session, and, because the cleared state
    /// reads as untouched, deleting its saved edit off disk. `dismiss` already defends against
    /// exactly this by nil-ing `loadedURL` first; this covers every other route into the window.
    @ObservationIgnored var perPhotoStateIsCleared = false

    /// Capture the current photo's state before leaving it.
    func stashCurrentSession() {
        guard let url = loadedURL, let full = fullResCI, let proxy = proxyCI else { return }
        // Nothing here belongs to `url` any more — see `perPhotoStateIsCleared`. The outgoing photo
        // was already stashed intact on the way into the clear, so there is nothing to lose.
        guard !perPhotoStateIsCleared else { return }
        let session = PhotoSession(
            url: url, imageId: imageId, fullResCI: full, proxyCI: proxy,
            originalPreviewImage: original.flatMap { $0.url == url ? $0.image : nil },
            perception: perception,
            candidates: candidates, proxyMaskBitmaps: proxyMaskBitmaps,
            subjectInstances: subjectInstances,
            subjectLuma: subjectLuma, subjectOrigin: subjectOrigin, skyLuma: skyLuma,
            healSpots: healSpots,
            capture: capture, activeLookId: activeLookId,
            maskAdjustments: maskAdjustments, maskFeather: maskFeather,
            maskTightness: maskTightness, maskInvert: maskInvert,
            selectedCandidateId: selectedCandidateId, edit: edit, editBaseline: editBaseline,
            baseMasks: baseMasks, maskEnabled: maskEnabled, maskStrength: maskStrength,
            userMasks: userMasks, straighten: straighten, hsl: hsl)
        sessions[url] = session
        sessionOrder.removeAll { $0 == url }
        sessionOrder.append(url)
        if session.isEdited { editedURLs.insert(url) } else { editedURLs.remove(url) }
        persistEdit(for: url)
        while sessionOrder.count > Self.maxSessions, let oldest = sessionOrder.first {
            sessions.removeValue(forKey: oldest); sessionOrder.removeFirst()
        }
    }

    /// Drop everything derived from the photograph being left behind.
    ///
    /// Not the same as `closeCurrentPhoto`, which also clears the URL and returns to the empty
    /// state — a switch is arriving somewhere rather than leaving. `loadedURL` deliberately stays
    /// put until the new photo actually loads, so a failed load can still be retried.
    func clearPerPhotoState() {
        activeRecipe = nil; preview.active = nil; original = nil; preview.lastRenderedCI = nil; preview.histogram = nil
        candidates = []; selectedCandidateId = nil; perception = nil
        activeCraftIssues = []; lastCraftReading = nil; exhaustedFixes = []
        userMasks = []; paintingMaskId = nil; selectedMask = nil; pickingInstance = false
        subjectInstances = []; highlightedInstanceId = nil
        proxyMaskBitmaps = [:]; brushCache = [:]; subjectOrigin = nil
        healSpots = []; healToolActive = false
        baseMasks = []; maskEnabled = [:]; maskStrength = [:]
        maskAdjustments = [:]; maskFeather = [:]; maskTightness = [:]; maskInvert = [:]
        hsl = [:]; straighten = 0; activeLookId = nil
        showingOriginal = false; showingRepairSpots = false; hoveringRepairControls = false
        // The grid is four renders of the photograph being left behind, and the comparison it
        // offers is not a comparison of the one arriving.
        comparing = false; compareRenders = [:]; comparePartnerId = nil
        // Per-PHOTOGRAPH, not per-shoot: an audit found the folder-change reset alone let a tick
        // survive a cached-session hop into a different shoot, and linger invisibly on frames
        // whose checkbox is hidden. Including a location is a decision about one photograph.
        shareIncludeLocation = false
        perPhotoStateIsCleared = true
        // A commit coalescing from the outgoing photograph must not fire against the incoming one.
        commitToken += 1
    }

    /// Put a previously-edited photo back exactly as it was.
    func restore(_ s: PhotoSession) {
        imageURL = s.url; imageId = s.imageId
        loadedURL = s.url
        perPhotoStateIsCleared = false
        // Per-PHOTOGRAPH, like the reset in `clearPerPhotoState` — and this is the path that reset
        // could not see. A cached hop never reaches `loadPhoto`, so without this a tick made for one
        // frame was still ticked on the next one, whose checkbox may not even be on screen.
        shareIncludeLocation = false
        fullResCI = s.fullResCI; proxyCI = s.proxyCI
        original = s.originalPreviewImage.map { TaggedPreview(url: s.url, image: $0) }
        perception = s.perception; candidates = s.candidates
        proxyMaskBitmaps = s.proxyMaskBitmaps
        subjectInstances = s.subjectInstances
        highlightedInstanceId = nil
        subjectLuma = s.subjectLuma; skyLuma = s.skyLuma; subjectOrigin = s.subjectOrigin
        healSpots = s.healSpots
        // Restored, not left standing. Every one of these was previously carried over from
        // whichever photo happened to be open before.
        capture = s.capture
        activeLookId = s.activeLookId
        maskAdjustments = s.maskAdjustments; maskFeather = s.maskFeather
        maskTightness = s.maskTightness; maskInvert = s.maskInvert
        selectedCandidateId = s.selectedCandidateId
        edit = s.edit; editBaseline = s.editBaseline
        baseMasks = s.baseMasks; maskEnabled = s.maskEnabled; maskStrength = s.maskStrength
        userMasks = s.userMasks; straighten = s.straighten; hsl = s.hsl
        brushCache = [:]; selectedMask = nil; paintingMaskId = nil; pickingInstance = false
        zoom = 1; pan = .zero; showingOriginal = false
        comparing = false; compareRenders = [:]; comparePartnerId = nil
        updateActiveRecipe()
        resetHistory()
        statusMessage = "\(s.url.lastPathComponent) · picking up where you left off"
        isProcessing = false
    }

    /// Close the current photo and go back to the empty state. The edit is saved first — closing
    /// is not discarding — and the session cache is kept, so reopening from the strip is instant.
    func closeCurrentPhoto() {
        stashCurrentSession()
        imageURL = nil; loadedURL = nil
        // Every early return in `loadPhoto` guards on `imageURL == url` and bails without reaching
        // the `isProcessing = false` at the end — so closing a photo mid-decode left the empty
        // state showing a spinner that never stopped.
        isProcessing = false
        fullResCI = nil; proxyCI = nil
        candidates = []; selectedCandidateId = nil
        activeRecipe = nil; preview.active = nil; original = nil
        preview.lastRenderedCI = nil; preview.histogram = nil; activeCraftIssues = []; lastCraftReading = nil; exhaustedFixes = []
        userMasks = []; paintingMaskId = nil; selectedMask = nil; pickingInstance = false
        subjectInstances = []; highlightedInstanceId = nil
        brushCache = [:]
        proxyMaskBitmaps = [:]; healSpots = []; healToolActive = false
        zoom = 1; pan = .zero; showingOriginal = false
        comparing = false; compareRenders = [:]; comparePartnerId = nil
        statusMessage = "Drop a photo or a folder to read the light."
    }

    /// Remove a photo from the strip for this session, and forget any edit it had. The file itself
    /// is never touched — this is about clearing the working set, not deleting someone's work.
    // MARK: Removing frames — from the working set, or from the disk

    /// Frames awaiting a confirmed trash. Non-empty puts the confirmation in front of the user.
    var pendingTrash: [URL] = []

    /// Ask to move frames to the Trash. Nothing happens until `confirmTrash` runs.
    func requestTrash(_ urls: [URL]) {
        let targets = urls.isEmpty ? [] : urls
        guard !targets.isEmpty else { return }
        pendingTrash = targets
    }

    /// What the confirmation says. Names the file when there is one, counts them when there are
    /// several — "Move 14 photos to the Trash" is a different decision from "move this one".
    var trashPrompt: String {
        pendingTrash.count == 1
            ? "Move “\(pendingTrash[0].lastPathComponent)” to the Trash?"
            : "Move \(pendingTrash.count) photos to the Trash?"
    }

    /// **Move to the Trash. Never unlink.**
    ///
    /// This is the only thing in Kelvin that touches an original, and it exists because culling a
    /// shoot by deletion is how photographers actually work — the scan finds forty frames where
    /// nothing came out sharp and they want them gone, not hidden.
    ///
    /// `trashItem` and not `removeItem`, and the difference is the whole design. Non-negotiable #3
    /// says the original is never written to; deleting one is a bigger departure than writing to it,
    /// so the only version of this worth shipping is the recoverable one. The Finder shows them, ⌘Z
    /// in the Finder puts them back, and the word "Trash" in the button says exactly that.
    ///
    /// **The edits are deliberately NOT deleted.** A trashed photo can be put back, and someone who
    /// restores a frame should find their work on it intact. Orphaned sidecars cost a few kilobytes;
    /// destroying an afternoon's editing because a file went to the Trash costs the afternoon.
    func confirmTrash() {
        let targets = pendingTrash
        pendingTrash = []
        guard !targets.isEmpty else { return }

        var trashed = 0
        var failures: [String] = []
        for url in targets {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed += 1
                // Out of the working set too, or the strip keeps drawing a frame that is gone.
                dismissedURLs.insert(url)
                editedURLs.remove(url)
                selectedPhotos.remove(url)
                sessions.removeValue(forKey: url)
                sessionOrder.removeAll { $0 == url }
                folderPhotos.removeAll { $0 == url }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        // If the open photo went with them, move to something still here rather than leaving the
        // canvas showing a file that no longer exists.
        if let open = imageURL, targets.contains(open) {
            if let next = folderPhotos.first {
                Task { await openPhoto(next) }
            } else {
                closeCurrentPhoto()
            }
        }

        if failures.isEmpty {
            statusMessage = "Moved \(trashed) photo\(trashed == 1 ? "" : "s") to the Trash — "
                + "recover them there if you change your mind"
        } else {
            statusMessage = "Moved \(trashed) to the Trash · \(failures.count) could not be moved "
                + "(\(failures.prefix(3).joined(separator: ", ")))"
        }
    }

    func dismiss(_ url: URL) {
        dismissedURLs.insert(url)      // survives the folder re-scan that happens on every open
        // THE SIDECAR STAYS. This called `EditStore.remove(for:)`, while the tooltip said "Remove
        // from this session" and this method's own doc comment said "The file itself is never
        // touched — this is about clearing the working set, not deleting someone's work." It was
        // deleting the work: hide a frame you had already edited and the edit was gone for good,
        // with nothing named delete anywhere near the click.
        //
        // Dismissing is about what is IN FRONT OF YOU. Un-dismiss the frame, or open it directly,
        // and the edit is still there — which is what "session" means.
        editedURLs.remove(url)
        sessions.removeValue(forKey: url)
        sessionOrder.removeAll { $0 == url }
        folderPhotos.removeAll { $0 == url }
        if url == imageURL {
            // Forget what is in memory BEFORE moving on, or the stash on the way to the next photo
            // writes this frame's session and sidecar straight back after they were just removed.
            loadedURL = nil
            original = nil; preview.active = nil
            if let next = folderPhotos.first {
                Task { await openPhoto(next) }
            } else {
                closeCurrentPhoto()
            }
        }
    }

    /// Switch photos from the filmstrip: stash what you were doing, then restore or load fresh.
    func openPhoto(_ url: URL) async {
        // `|| loadedURL != url` so a photo whose load failed can be retried. Without it, a transient
        // failure left `imageURL` set and this guard then refused every attempt at the same file.
        // It used to read `proxyCI == nil`, which stopped being true after the FIRST photo loaded:
        // a failed decode leaves the previous photo's proxy in place, so the retry was refused.
        guard url != imageURL || loadedURL != url else { return }
        stashCurrentSession()
        if let cached = sessions[url] {
            // The cached path never reaches `loadPhoto`, so the shoot-change housekeeping that
            // lives there has to happen here too: a halted (or still-sweeping) read queue from
            // folder A must not govern folder B — an audit found a 400-frame sweep still burning
            // GPU under another folder's cached frames, with the old folder's counts in the
            // toolbar. Same folder, nothing changes.
            //
            // `restore` first, so `enterShoot`'s `imageURL == url` contract holds and the strip is
            // never re-listed for a photograph the user has already left. The read-ahead reset that
            // used to be spelled out here now lives inside `enterShoot`'s folder-change block,
            // together with the rest of the housekeeping it was separated from.
            let folder = url.deletingLastPathComponent()
            restore(cached)
            sessionOrder.removeAll { $0 == url }; sessionOrder.append(url)
            if shootLookFolder != folder { await enterShoot(around: url) }
            // The anchor still moved — the neighborhood re-seeds around the frame now on screen.
            seedNeighborhoodRead()
            return
        }
        await loadPhoto(from: url)
    }

    /// Arrive in the shoot a photograph belongs to: list it, sort it, and reset everything that
    /// names one folder. Returns false if the photograph was superseded while the listing was in
    /// flight, in which case the caller must abandon the load.
    ///
    /// BOTH arrival paths go through this, and that is the point. When only `loadPhoto` did it, a
    /// cached-session hop into a different folder left the strip listing the old shoot, the shoot
    /// look and its style belonging to the old shoot, and the selection and export label still
    /// naming it — so Apply and Export edited operated on a folder the user had left.
    @discardableResult
    func enterShoot(around url: URL) async -> Bool {
        // `includeFolderOnOpen` off means exactly this photograph and nothing else. The strip
        // disappears (it only draws above one photo), which also takes the arrow keys, culling and
        // Batch apply with it — that is the deal, and it is the user's to make.
        // The listing goes off the main actor for the reason `open` documents: it is a `readdir`
        // plus a stat per entry, and on a share that is the first place the window can freeze.
        let siblings: [URL]
        if includeFolderOnOpen {
            let listed = await Offload.run(.io) {
                PhotoBrowser.siblings(of: url)
            }
            siblings = listed.filter { !dismissedURLs.contains($0) || $0 == url }
        } else {
            siblings = [url]
        }
        // The photograph may have been superseded while the listing was in flight — arrowing through
        // a shoot faster than a share can answer is exactly when that happens. Same contract as
        // every other `imageURL == url` guard in this file.
        guard imageURL == url else { return false }
        folderPhotos = PhotoOrder.sorted(siblings, by: photoSort,
                                         reversed: photoSortReversed, captureDates: captureIndex.dates)
        // THE REST OF THE FOLDER IS NOT READ UNTIL YOU ASK TO SEE IT.
        //
        // Reported as "it automatically opens every single photo in the folder", and that was
        // fair. Listing the directory is one cheap readdir, but everything after it was per-file
        // and ran unconditionally: an EXIF header read for every sibling, a sidecar existence
        // check for every sibling, a flag lookup for every sibling. Open one frame in a
        // 437-photo shoot and that is some thirteen hundred file operations nobody asked for,
        // for a strip that is folded shut.
        //
        // So the enrichment waits for the strip. Folded, opening a photo touches that photo.
        // Unfolded — which is what opening a FOLDER means — it runs immediately, because then
        // the shoot is the thing you asked for.
        loadFolderDetailIfVisible(for: url.deletingLastPathComponent(), photos: siblings)
        // The shoot's look, before the candidates are built — `buildCandidates` needs it to know
        // which style to open this frame in. One small JSON read, and only when the folder changes.
        let folder = url.deletingLastPathComponent()
        // Leaving the shoot ends the read-ahead with it: those seconds belong to the folder someone
        // is working on, not to one they have walked away from. Reset rather than halt — the new
        // folder is allowed to read its own neighborhood.
        if shootLookFolder != folder {
            selectedPhotos = []; selectionAnchor = nil
            resetReadAhead()
            // The export label names ONE shoot. Carrying "Lake Como" into the next folder is how a
            // Reykjavik wedding gets delivered labelled Lake Como — a mistake nobody would catch
            // until a client did.
            exportLabel = ""
            // Same shape of mistake, worse payload: an "Include location" ticked for one shoot
            // must not still be ticked when a different shoot gets texted to someone else.
            shareIncludeLocation = false
        }
        loadShootLook(for: folder)
        return true
    }

    /// What one `stat` off the main actor found at a path, so `open` can decide what to do without
    /// touching the filesystem itself. See the note in `open`.
    private enum OpenTarget: Sendable {
        case missing
        case file
        /// The frame to open, already sorted by filename. Nil means a folder with nothing readable.
        case folder(first: URL?)
    }

    /// The single way a photo gets into Kelvin, whatever the source — the Open panel, ⌘O, a drop,
    /// or the filmstrip. Everything funnels here so opening behaves identically in every case:
    /// a folder opens its first frame, an already-open photo's edit is stashed rather than lost,
    /// and anything unreadable says so instead of failing silently.
    func open(_ url: URL) async {
        // OFF THE MAIN ACTOR, ALL OF IT. `AppState` is `@MainActor`, so the `stat` and the directory
        // listing below used to run on the main thread. On an internal SSD that is free; on a share
        // that has gone to sleep or lost its route, a single `stat` blocks in the kernel for as long
        // as the mount's timeout — tens of seconds — and because it is the main thread the window
        // cannot paint and there is no way to cancel. That is the beachball people reported when
        // opening a photograph from a NAS, and it happened before Kelvin had read a single byte of
        // the file.
        let probe = await Offload.run(.io) { () -> OpenTarget in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return .missing
            }
            guard isDirectory.boolValue else { return .file }
            // The directory listing belongs in here too. One `readdir` is cheap in principle, but
            // over SMB it is a round trip plus a stat storm for the extension filter.
            let files = (try? BatchApply.imageFiles(in: url))
                .map { PhotoOrder.sorted($0, by: .filename) } ?? []
            return .folder(first: files.first)
        }

        switch probe {
        case .missing:
            statusMessage = "That file isn't there any more."
            return
        case .folder(let first):
            // Dragging a shoot folder in is a natural thing to try; open the first frame and let
            // the filmstrip carry the rest.
            guard let first else {
                statusMessage = "No photos \(Branding.displayName) can read in \(url.lastPathComponent)."
                return
            }
            // Opening a folder is an explicit request for the shoot, so the strip starts open.
            // (First frame by filename, not capture time — picking by time would mean reading
            // every EXIF header before the first photo could appear. Once the dates land the strip
            // re-sorts around whichever frame is open, which costs nothing.)
            FilmstripFold.applyOpenIntent(openedFolder: true)
            await openPhoto(first)
            return
        case .file:
            break       // handled below
        }
        guard BatchApply.imageExtensions.contains(url.pathExtension.lowercased()) else {
            statusMessage = "\(Branding.displayName) can't read .\(url.pathExtension) files."
            return
        }
        // One file was asked for, so one file is what takes over the screen. The rest of the folder
        // is still listed and one click away — it just does not arrive uninvited.
        FilmstripFold.applyOpenIntent(openedFolder: false)
        await openPhoto(url)
    }

    /// Resolve a drag-and-drop payload to a file and open it. Takes the first item that resolves,
    /// so dragging a selection of several frames opens one rather than doing nothing.
    func openDropped(_ providers: [NSItemProvider]) async {
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url {
                await open(url)
                return
            }
        }
        statusMessage = "Couldn't read what was dropped."
    }

    /// The Open panel, behind both File ▸ Open… (⌘O) and the empty state's button.
    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .rawImage]
        panel.allowsMultipleSelection = false
        // Choosing a folder opens the shoot — the same thing dropping one does.
        panel.canChooseDirectories = true
        panel.prompt = "Open"
        // Reported as confusing, and fairly: the button said "choose a photo" while the panel
        // quietly accepted folders and opening one frame listed its neighbours in the strip. The
        // behaviour is deliberate — a shoot is the unit of work — but nothing said so, which made
        // it read as the app doing something it had not been asked to do.
        panel.message = "Open one photo, or a folder to work through a whole shoot."
        // The checkbox that makes the folder listing a decision rather than a surprise.
        // AppKit, not SwiftUI — see PanelAccessories. A hosting view inside a modal panel renders
        // once and then stops updating, so the checkbox looked stuck while the preference behind it
        // flipped on every click.
        panel.accessoryView = PanelAccessories.openOptions(self)
        panel.isAccessoryViewDisclosed = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await open(url) }
        }
    }

    /// "· 9 more in this folder", or nothing when there are none and nothing when the folder was not
    /// listed at all.
    ///
    /// The other half of the reported confusion: a folder appearing in the strip was a surprise
    /// because nothing ever said it had happened. Saying it costs one clause and removes the
    /// surprise entirely — and when the count is zero or the setting is off, it says nothing, so it
    /// never becomes noise.
    var statusNote: String {
        let others = folderPhotos.count - 1
        guard includeFolderOnOpen, others > 0 else { return networkNote }
        return " · \(others) more \(others == 1 ? "photo" : "photos") in this folder" + networkNote
    }

    /// Whether the open photograph lives on a share. Read from a stored flag rather than asked per
    /// view update — `StorageVolume.isNetwork` is a syscall on first sight of a volume, and this is
    /// on the path that draws the footer.
    private(set) var onNetworkVolume = false

    /// Said once a shoot is open, and only when it is somewhere slow.
    ///
    /// The first read of a frame from a NAS is genuinely slower and there is nothing to be done about
    /// the physics of it. What was wrong before was the silence: identical messages for a local disk
    /// and a share meant the only available reading of a slow open was that the app was broken.
    /// Everything cached is cached, so this describes the first read and says so.
    private var networkNote: String {
        onNetworkVolume ? " · on a network volume, so the first read of each frame is slower" : ""
    }

    func loadPhoto(from url: URL) async {
        Self.latestRequest.set(url)
        let openedAt = Date()
        Self.lifecycle.notice("open \(url.lastPathComponent, privacy: .public)")
        isProcessing = true
        statusMessage = "Decoding…"
        // Keep whatever you were working on before this photo takes over.
        if loadedURL != nil, loadedURL != url { stashCurrentSession() }
        // AND THEN LET GO OF IT. Reported as "it tries to apply settings from the old pic, and the
        // preview stays on the previous one".
        //
        // Everything derived from a photograph — the recipe, the candidates, the rendered preview,
        // the craft flags, the masks measured on its proxy — used to survive until the NEW
        // photograph's equivalents replaced it, several seconds later. In between, the sliders held
        // the previous frame's values, the footer showed its colour temperature, and the canvas
        // showed its pixels, all under the new photo's name. Anything the user touched in that
        // window applied the old frame's numbers to the new frame.
        //
        // Stashed first, so nothing is lost — this only clears what has just been saved.
        if loadedURL != url { clearPerPhotoState() }
        imageURL = url
        guard await enterShoot(around: url) else { return }
        // An EXIF header read, off the main actor and through the cache. It is one file open, which
        // is nothing locally and a round trip on a share — and it sat on the main thread in front of
        // the decode, so the window could not even paint the new filename until it came back.
        let opened = await Offload.run(.io, priority: .veryHigh) {
            // Both answers come out of the same trip to the filesystem, and neither belongs on the
            // main thread. `isNetwork` is one `statfs` and cached per volume after the first frame.
            (capture: MediaCache.shared.captureInfo(for: url), onNetwork: StorageVolume.isNetwork(url))
        }
        guard imageURL == url else { return }
        capture = opened.capture
        onNetworkVolume = opened.onNetwork
        // The open frame's own place, resolved immediately. The folder-wide pass only runs when the
        // strip is unfolded, so opening a single photograph found the coordinate and never asked
        // what it was called — the one case most likely to be someone's first look at the feature.
        if let here = capture.location {
            PlaceNames.shared.resolve(here)
            PlaceMaps.shared.fetch(here)
        }
        userMasks = []; paintingMaskId = nil; selectedMask = nil; pickingInstance = false   // hand-drawn masks are per-photo
        // The subjects belong to the photograph, so they go out with it. Left standing,
        // the list would offer the last photo's people while this one decoded.
        subjectInstances = []; highlightedInstanceId = nil
        zoom = 1; pan = .zero
        // FIRST PAINT FROM THE CAMERA'S OWN PREVIEW, while Apple's decode runs. A 60 MP RAW is a
        // second or more to decode and the canvas used to show nothing for all of it; the JPEG the
        // camera embedded is tens of milliseconds away and is the same photograph, if not the same
        // rendering of it. It goes into `original` — what the canvas shows until the first live
        // render lands — and the real decode replaces it the moment it arrives. Nothing downstream
        // measures or keeps it: `measurementProxy` documents why the camera's colour is not ours.
        Task { [weak self] in
            let quick = await Offload.run(.render, qos: .userInteractive) { () -> CGImage? in
                guard let ci = PerceptionProxy.measurementProxy(url, maxEdge: 1200) else { return nil }
                return Self.sharedContext.createCGImage(ci, from: ci.extent)
            }
            guard let self, let quick, self.imageURL == url, self.original == nil else { return }
            self.original = TaggedPreview(url: url, image: NSImage(cgImage: quick, size: .zero))
        }
        do {
            // DECODE OFF THE MAIN THREAD. Decoding a 60 MP RAW, materialising the proxy and
            // SHA-256-ing a 60 MB file together take many seconds; run on the main thread they
            // block every frame, so the window could not paint and the app looked dead on exactly
            // the files it exists to edit.
            //
            // ON THE DECODE LANE, AT THE HEAD OF IT. This is the photograph somebody is waiting
            // for; a read-ahead decode queued on the same lane yields its place. See `Offload`.
            let decoded = try await Offload.run(.decode, priority: .veryHigh) { () throws -> DecodedPhoto in
                guard Self.latestRequest.isCurrent(url) else { throw CancellationError() }
                let fullRes = try ImageDecoder.decode(url: url)

                // The model wants a small 768px proxy (non-negotiable #4); the EDIT proxy is a bit
                // larger so zooming shows more detail, but not so large that live rendering slows
                // down (1200px balances zoom detail against snappy sliders). Masks build from it,
                // so they stay aligned when zoomed.
                //
                // THE SMALL ONE IS DERIVED FROM THE LARGE ONE, and that is worth ~900 ms of every
                // RAW open. Both used to be built from the 60 MP decode: for RAW `fromFile` refuses
                // (it would hand back the camera's own JPEG and throw away Apple's decode — see
                // `PerceptionProxy.fromFile`), so each was a full Lanczos pass over 60 megapixels,
                // measured at 1326 ms and 937 ms. Going 1200 -> 768 instead costs almost nothing.
                //
                // It is a two-step resample rather than a one-step, so the pixels are not identical
                // — and every recipe number is measured on this image, which is exactly the sort of
                // silent change this codebase has been bitten by before. So it was measured rather
                // than assumed, with `kelvin-cli proxy-compare` over 79 real frames (60 MP Sony
                // RAWs and studio JPEGs): worst mean-luma difference 0.001, and the engine produced
                // an **identical recipe on 78 of 79** — the one exception differing by 0.01 EV,
                // which is a hundredth of a stop and below the recipe's own rounding.
                //
                // MATERIALISE the edit proxy. `downsample` returns a *lazy* CIImage — a filter
                // graph over the full-resolution original — so every later measurement (mask
                // coverage, subject luma, dust scan, histogram) silently re-renders all 60
                // megapixels again. Rendering once here means everything downstream works on real
                // 1200 px pixels.
                //
                // Better still, for anything that is not RAW, is never to decode the full frame:
                // ImageIO can decode a JPEG straight to the size we want. Profiled on a 9504×6336
                // frame, the proxy went 2017 ms -> 120 ms, which was the single largest cost in
                // opening a photo. RAW keeps the real decode — see `PerceptionProxy.fromFile` for
                // why taking the camera's embedded preview would be wrong rather than merely
                // faster.
                let proxy = PerceptionProxy.fromFile(url, maxEdge: 1200, matching: fullRes.extent)
                    ?? Self.materialiseDecoded(PerceptionProxy.downsample(fullRes, maxEdge: 1200))
                // Derived from the edit proxy above, and materialised for the same reason it is:
                // left lazy, every measurement downstream would re-run the 1200 px scale.
                let perceptionProxy = Self.materialiseDecoded(PerceptionProxy.downsample(proxy))
                let preview = Self.decodeContext.createCGImage(proxy, from: proxy.extent)
                    .map { NSImage(cgImage: $0, size: NSZeroSize) }
                return DecodedPhoto(fullRes: fullRes, perceptionProxy: perceptionProxy,
                                    proxy: proxy, originalPreview: preview)
            }
            guard imageURL == url else { return }
            Self.lifecycle.notice("decoded \(url.lastPathComponent, privacy: .public) in \(Int(Date().timeIntervalSince(openedAt) * 1000)) ms")

            // The decode has landed, so these images now belong to `url` — and `loadedURL` moves
            // with them, in the same breath, never before.
            self.fullResCI = decoded.fullRes
            self.proxyCI = decoded.proxy
            // THE CONTENT HASH NO LONGER HOLDS UP THE PICTURE.
            //
            // It used to be computed inside the decode above, which meant every byte of the file was
            // read and hashed before anything appeared on screen. For a 60 MP RAW on a share that is
            // a 60 MB transfer standing in front of a proxy that needs a fraction of it — and it
            // bought a provenance string that nothing on the way to showing a photograph reads.
            //
            // It is wanted by `currentSavedEdit` and `recordCurrentPick`, both of which are reached
            // by someone moving a slider or choosing a candidate — long after this lands. Cleared
            // first so a stale hash can never be stamped onto the new frame's edit in the gap.
            self.imageId = ""
            self.hashTask?.cancel()
            self.hashTask = Task { [weak self] in
                // On the scan lane so a burst of hashes never queues in front of an open's EXIF
                // read (see `Offload.Lane.io`) — but at the front of that lane, because a save
                // waits on this and a focus scan can hold the lane for seconds.
                let id = await Offload.run(.scan, qos: .utility, priority: .veryHigh) {
                    MediaCache.shared.imageId(for: url)
                }
                guard let self, let id, self.imageURL == url else { return }
                self.imageId = id
            }
            self.loadedURL = url
            self.perPhotoStateIsCleared = false
            // The untouched original, for the before/after compare.
            self.original = decoded.originalPreview.map { TaggedPreview(url: url, image: $0) }
            let perceptionProxy = decoded.perceptionProxy
            let proxy = decoded.proxy

            // The FIRST read of a session is not like the others: 1.6 GB of weights load before
            // anything is looked at, which is fifteen seconds where a message identical to the
            // two-second reads that follow makes a working app look like a hung one. Say which one
            // this is. The flag flips once, so the long sentence never becomes wallpaper.
            statusMessage = hasReadAPhoto
                ? "Reading the scene…"
                : "Loading the perception model — about 15 seconds, once per launch…"
            // Real perception: Qwen2.5-VL reads the 768px proxy. First call loads the model (a few
            // seconds once cached); if it can't run, fall back to a conservative read so the
            // app still produces candidates from the measured statistics.
            let perceptionRead: Perception
            if let cached = PerceptionStore.load(for: url, modelId: perceptionProvider.activeModelID) {
                // ALREADY READ, IN AN EARLIER SESSION. A read is a pure function of the pixels, so
                // this is the same answer the model would spend six seconds producing again.
                perceptionRead = cached
                await rememberPerception(cached, for: url)
                statusMessage = "Already read — reusing it"
            } else if let shared = await reusablePerception(for: url) {
                // Same picture, same answer. See `reusablePerception`.
                perceptionRead = shared
                statusMessage = "Same scene as a frame already read — reusing it"
            } else {
                // ONE read in flight, ever. The provider is an actor, so reads queue — and a read
                // for a photograph the user has already arrowed away from would still burn its
                // seconds of generation ahead of the frame on screen. Cancelling the previous
                // task makes the abandoned read throw at the actor's door instead of running.
                perceiveTask?.cancel()
                // The read-ahead loop may be holding the model MID-GENERATION — up to five
                // seconds this click would otherwise queue behind. The provider checks
                // cancellation between tokens, so this takes the model back now; the loop
                // catches it, re-enqueues that frame, and waits for this load to finish.
                backgroundReadTask?.cancel()
                let job = Task { [perceptionProvider] in
                    try await perceptionProvider.perceive(perceptionProxy)
                }
                perceiveTask = job
                do {
                    perceptionRead = try await job.value
                    await rememberPerception(perceptionRead, for: url)
                    // Kept, so no later session and no export pays for this read again.
                    PerceptionStore.save(perceptionRead, for: url,
                                         modelId: perceptionProvider.activeModelID)
                } catch is CancellationError {
                    // A newer photo superseded this one mid-read. Its own load owns the window
                    // now — same contract as every `imageURL == url` guard in this function.
                    return
                } catch {
                    perceptionRead = Self.conservativeRead
                    statusMessage = "Couldn't run the perception model — using a conservative read"
                }
            }
            guard imageURL == url else { return }
            self.perception = perceptionRead
            Self.lifecycle.notice("perceived \(url.lastPathComponent, privacy: .public) at \(Int(Date().timeIntervalSince(openedAt) * 1000)) ms — \(self.statusMessage, privacy: .public)")

            hasReadAPhoto = true
            statusMessage = "Measuring…"
            // Also off the main thread: the statistics pass, Vision's person/sky segmentation and
            // the dust scan each render the proxy, and together they were the second-biggest block
            // on the main thread after decode.
            // ...and partly CONCURRENTLY. These passes take no input from each other and ran one
            // after another for 973–1058 ms, dominated by subject instances (631–746 ms) with
            // everything else waiting behind it for no reason.
            //
            // BUT THE VISION PASSES MUST STAY SERIAL WITH EACH OTHER. Running all four at once
            // crashed the app: EXC_BAD_ACCESS in `objc_release` inside Vision's own
            // `VNGenerateSemanticSegmentationCompoundRequest detectorTypeForSemanticSegmentationRequest`,
            // on Vision's request queue. `LocalMasks.measure` and `SubjectInstances.detect` both
            // perform person segmentation, and Vision over-releases something while resolving
            // which detector to use for two of those at once. It is a race, so it is intermittent
            // — reproduced at 2 crashes in 6 runs through the CLI's `bench-load --only par`, which
            // is exactly the sort of failure that reaches a user and not a test.
            //
            // The focus measure touches no Vision at all (a Laplacian), so it still overlaps the
            // Vision block for free. The win drops from ~28% to ~15%. A quarter of a second is
            // not worth a segfault.
            // The image every recipe decision is measured on. Named, because the difference between
            // this and `proxy` is load-bearing — see the block below.
            let measureOn = perceptionProxy
            let measureInputs = MeasureInputs(proxy: proxy, measureOn: measureOn)
            let measurement = try await Task.detached(priority: .userInitiated) { () throws -> MeasuredPhoto in
                // Two lanes, AWAITED from this task rather than run on it: the focus read is Core
                // Image and overlaps; everything that touches Vision goes through the serial vision
                // lane. Neither holds a cooperative thread while it works — see `Offload`.
                async let focus = Offload.run(.render) { FocusMeasure.read(measureInputs.proxy) }

                // MEASURED ON THE PERCEPTION PROXY, NOT THE EDIT PROXY — and this is the whole
                // point of the change, not an optimisation.
                //
                // `adaptedRecipe` measures here, at 768 px. This measured at 1200 px. Both then
                // applied the same curation rule to different numbers, so the canvas and the
                // export could resolve a shoot's style to DIFFERENT CANDIDATES for the same
                // photograph — measured on 15 real 60 MP frames, 1 in 15 at ΔE 4.54, plainly
                // visible. The mechanism is a hard-threshold straddle rather than anything subtle:
                // on `_DSC3937.ARW`, `subjectLuma` differed by 0.007 between the two sizes, which
                // moved Dramatic's aesthetic score from 0.572 to 0.523 across a `qualityFloor` of
                // 0.55, and the curator dropped a style on one side and kept it on the other.
                //
                // Neither size was "right" — 0.572 and 0.523 straddle the line by coin-flip — so
                // the fix is one measurement, not a better one. 768 wins because it is what export
                // must use anyway (it has no edit proxy) and it is 41% of the pixel work.
                //
                // `focus` and `instances` deliberately stay on the 1200 px edit proxy: neither
                // feeds a recipe or a curation decision. They are the strip's triage and the
                // click-to-mask targets, and they want the finer image.
                let rest = try await Offload.run(.vision) { () throws -> MeasuredSansFocus in
                    guard Self.latestRequest.isCurrent(url) else { throw CancellationError() }
                    let sampleBytes = try ImageMetrics.sample(measureInputs.measureOn)
                    let stats = ImageStatistics.compute(from: sampleBytes)
                    // Serial, deliberately. Do not turn these into `async let`.
                    let masks = LocalMasks.measure(in: measureInputs.measureOn)
                    let instances = SubjectInstances.detect(in: measureInputs.proxy)
                    return MeasuredSansFocus(stats: stats, masks: masks, instances: instances)
                }
                return await MeasuredPhoto(stats: rest.stats, masks: rest.masks,
                                           focus: focus, instances: rest.instances)
            }.value

            guard imageURL == url else { return }

            let stats = measurement.stats
            self.subjectInstances = measurement.instances
            // Each instance's bitmap goes in under its own id, so a mask naming that instance
            // renders it. `LocalMasks`' merged "subject"/"sky" stay alongside — the engine's
            // automatic local edits still use those.
            //
            // The subject/sky masks are measured at 768 and RENDERED at 1200, so they are scaled
            // onto the edit proxy here. That loses nothing real: `SubjectMask` gets a fixed-size
            // buffer back from Vision whatever it is handed, and `SkyMask` classifies on a 160-px
            // grid, so both were already being scaled up to whatever extent was asked for. The
            // instance masks come from the edit proxy and are already at its extent.
            self.proxyMaskBitmaps = measurement.masks.bitmaps
                .mapValues { Self.scaleMask($0, to: proxy.extent) }
                .merging(measurement.instances.reduce(into: [:]) { $0[$1.id] = $1.mask }) { a, _ in a }
            self.subjectLuma = measurement.masks.subjectLuma
            self.subjectOrigin = measurement.masks.subjectOrigin
            self.skyLuma = measurement.masks.skyLuma
            // NOT scaled: the candidates are scored on the 768 px image these were measured on, so
            // that the score the curator sees is the score the export's curator sees.
            let proxyMasks = measurement.masks.bitmaps

            self.focus[url] = measurement.focus

            statusMessage = "Composing candidates…"
            // Clean candidates straight from the engine — no cross-image "profile". The way to
            // reuse an edit is to pick/tune one photo, then Batch apply that exact look.
            let recipes = RecipeEngine.candidates(perception: perceptionRead, statistics: stats,
                                                  subjectLuma: self.subjectLuma, skyLuma: self.skyLuma,
                                                  subjectOrigin: self.subjectOrigin,
                                                  iso: ExifReader.iso(url: url))

            // Render every style, score each on the craft floors, then CURATE. The engine offers
            // eight looks and several will be wrong for any given photo — Dramatic silhouettes a
            // backlit sunset, Vivid pushes skin past plausible. Showing those beside the good ones
            // makes the photographer do the culling and implies Kelvin rates them equally. It
            // doesn't, and the evaluator already knows which is which.
            // Rendering eight candidates and scoring each — every score runs Vision face detection
            // and a full statistics pass — is far too much to do on the main thread: it froze the
            // window for the whole of it. Hand the batch to a background task and come back with
            // the results.
            let built = await Task.detached(priority: .userInitiated) { () -> CandidateBatch in
                // TWO PHASES, and the split is a crash-avoidance decision rather than a tidy one.
                //
                // This was one serial loop over eight styles, measured at 378 ms in release and
                // 515 ms in debug — the whole of "Composing candidates…", and the wait people
                // describe as the app being slow. The eight jobs are independent, so the obvious
                // move is to run them together.
                //
                // What stops that being one `withTaskGroup` around the whole body: scoring calls
                // `AestheticEvaluator.score(rendered:)`, which calls `FaceSkin.read`, which runs
                // **Vision**. Running Vision requests concurrently is exactly what crashed this app
                // before — EXC_BAD_ACCESS in `objc_release` inside Vision's own request queue,
                // intermittent at 2 crashes in 6 runs, documented at the measurement site in
                // `loadPhoto`. A quarter of a second is not worth a segfault, and it was not worth
                // one then either.
                //
                // So: phase one is Core Image and statistics, which are thread-safe and are the
                // expensive half — run concurrently. Phase two is the Vision read, kept strictly
                // serial. Every candidate is still rendered and scored on the same 768 px
                // measurement image with the same inputs, so no number here changes; only the
                // wall-clock does.
                struct Prepared: @unchecked Sendable {
                    let index: Int
                    let recipe: Recipe
                    let rendered: CIImage
                    let cg: CGImage
                    let stats: ImageStatistics
                }

                // The renderer's INPUTS, boxed, for the same reason `Prepared` above boxes its
                // outputs: `CIImage` is `Sendable` on the macOS 27 SDK and is NOT on the one CI
                // builds against (Xcode 16.4 / macOS 15.5), so capturing `measureOn` and
                // `proxyMasks` directly in the task-group closure below compiles on this machine and
                // fails for everybody else. Boxing states the promise once, in the place where the
                // reasoning for it belongs.
                //
                // The promise is the same one `Prepared` already makes and it is sound: these two
                // values are read-only for the whole of the group's life, `Renderer.render` does not
                // mutate what it is handed, and Core Image is documented thread-safe for concurrent
                // reads of an immutable `CIImage`.
                struct Inputs: @unchecked Sendable {
                    let measureOn: CIImage
                    let masks: [String: CIImage]
                }
                let inputs = Inputs(measureOn: measureOn, masks: proxyMasks)

                let prepared: [Prepared] = await withTaskGroup(of: Prepared?.self) { group in
                    for (index, recipe) in recipes.enumerated() {
                        group.addTask {
                            // ON THE RENDER LANE, not on this pool thread. Eight of these used to
                            // block eight cooperative threads on one context's lock — see the note
                            // at the top of `Offload` for what that cost. The group still runs
                            // them together; the lane decides how many render at once.
                            await Offload.run(.render) { () -> Prepared? in
                                guard Self.latestRequest.isCurrent(url) else { return nil }
                                // Rendered on the 768 px measurement image, matching
                                // `adaptedRecipe` exactly. The previews are picker thumbnails,
                                // so 768 is ample.
                                let renderedCI = Renderer.render(inputs.measureOn, with: recipe,
                                                                 maskBitmaps: inputs.masks)
                                guard let cg = Self.sharedContext.createCGImage(
                                          renderedCI, from: renderedCI.extent),
                                      let stats = try? ImageStatistics.compute(renderedCI)
                                else { return nil }
                                return Prepared(index: index, recipe: recipe,
                                                rendered: renderedCI, cg: cg, stats: stats)
                            }
                        }
                    }
                    var out: [Prepared] = []
                    for await item in group { if let item { out.append(item) } }
                    // A task group completes in whatever order the work finishes. The curator is
                    // fed a list and ties on score are broken by position, so an order that
                    // depends on which GPU job landed first would make the candidate set
                    // non-deterministic between runs on the same photograph. Sorted back into
                    // engine order.
                    return out.sorted { $0.index < $1.index }
                }

                // The Vision half, on its serial lane.
                return await Offload.run(.vision) { () -> CandidateBatch in
                guard Self.latestRequest.isCurrent(url) else {
                    return CandidateBatch(scored: [], previews: [:])
                }

                // ONE face detection for the whole set, not one per candidate.
                //
                // Eight candidates are eight gradings of ONE photograph, so detecting faces in each
                // was finding the same faces eight times — measured as roughly half the entire
                // candidate stage. `FaceSkin.detect` runs Vision once here; `meter` then reads the
                // skin inside those boxes per candidate, which is a 32×32 sample and touches no
                // Vision at all.
                //
                // Metering still happens per candidate, because that is the part that must differ:
                // skin plausibility is exactly the question "what did THIS grade do to their skin".
                // Holding the face set constant across the eight also makes the comparison a fairer
                // one than it was — a detection that shifted between candidates would have them
                // answering slightly different questions.
                let faces = FaceSkin.detect(in: inputs.measureOn)

                var scored: [CandidateCurator.Scored] = []
                var previews: [String: NSImage] = [:]
                for item in prepared {
                    let face = FaceSkin.meter(in: item.rendered, faces: faces)
                    let score = AestheticEvaluator.score(stats: item.stats, face: face)
                    let key = item.recipe.id ?? UUID().uuidString
                    previews[key] = NSImage(cgImage: item.cg, size: .zero)
                    scored.append(.init(recipe: item.recipe, score: score))
                }
                return CandidateBatch(scored: scored, previews: previews)
                }
            }.value
            // Building candidates is now asynchronous, so a second photo can be opened while the
            // first is still working. Without this guard those results would land on whichever
            // photo happens to be showing — thumbnails from one frame beside the preview of
            // another. If we've moved on, drop them.
            guard imageURL == url else { return }
            Self.lifecycle.notice("candidates for \(url.lastPathComponent, privacy: .public) at \(Int(Date().timeIntervalSince(openedAt) * 1000)) ms — \(built.scored.count) scored")
            let scored = built.scored
            let previews = built.previews
            // THE SHOOT'S LOOK DECIDES WHICH CANDIDATE OPENS, when the shoot is in one — and the
            // rule for that, including what happens when the curator drops the style, lives in
            // `CandidateCurator.resolve` so the export path resolves it the same way. It used to
            // live here as a comment, and the export path did not honour it.
            let wanted = effectiveStyle(for: url)
            let resolution = CandidateCurator.resolve(from: scored, requested: wanted, count: 4)
            let curated = resolution.curated
            self.candidates = curated.compactMap { item in
                let key = item.recipe.id ?? ""
                guard let image = previews[key] else { return nil }
                return CandidateViewModel(
                    id: key,
                    label: item.recipe.label ?? key,
                    baseRecipe: item.recipe,
                    previewImage: image)
            }
            let models = self.candidates
            // This is what makes applying a look to a folder mean anything: the style was chosen
            // once, and every frame resolves it against its own histogram, its own scene reading and
            // its own masks — which is exactly what `candidates` already are, one per style, built
            // from THIS photograph. So honouring the shoot look is choosing among them, not
            // replaying somebody else's numbers.
            let shootStyle = resolution.honouredRequest
                ? models.first { $0.id == resolution.chosen?.recipe.id }
                : nil
            if let shootStyle { selectCandidate(id: shootStyle.id) }
            else if let first = models.first { selectCandidate(id: first.id) }

            // If this photo was edited in an earlier session, put that work back rather than
            // handing back a fresh candidate and quietly losing it.
            //
            // A HAND-MADE EDIT OUTRANKS THE SHOOT'S LOOK, always — it is applied last and it is the
            // one thing in this app that is not a guess. See `ShootLook`.
            if let saved = EditStore.load(for: url) {
                apply(saved)
                editedURLs.insert(url)
                statusMessage = "Ready · restored your edit from \(Self.friendlyDate(saved.savedAt))\(statusNote)"
            } else if let shootStyle {
                statusMessage = "Ready · \(shootStyle.label), adapted to this frame from the shoot's look\(statusNote)"
            } else if let wanted, let style = CandidateStyle.all.first(where: { $0.id == wanted }) {
                // Say so rather than quietly showing a different look than the strip implies.
                statusMessage = "Ready · the shoot is in \(style.label), but that look is wrong for "
                    + "this frame — showing \(models.first?.label ?? "the best fit") instead\(statusNote)"
            } else {
                statusMessage = "Ready · pick a look, then apply it to the shoot\(statusNote)"
            }
            // Offer to become the default photo app — here, and only here, because this is the first
            // moment the question has a subject. A photograph is on screen with its candidates up, so
            // the user has just seen what a double-click would get them. Asked at launch it would be a
            // modal in front of an empty window. Asks once, ever; see DefaultAppPrompt.
            DefaultAppPrompt.offerIfAppropriate()
            // The automated slider drag, when asked for. Here because it needs what a real drag
            // needs: a photo open and a candidate loaded. See Diagnostics.swift.
            if let steps = StressDrag.steps {
                let baseline = edit.exposureEV
                Task { [weak self] in
                    await StressDrag.run(steps: steps) { [weak self] ev in
                        guard let self else { return }
                        self.edit.exposureEV = baseline + ev
                        self.onEdit()
                    }
                }
            }
        } catch {
            // Only if this load is still THE load. Arrow off an unreadable frame and its decode
            // fails after the next photo's load has begun — without the guard, this error
            // stamped itself over the successor's "Decoding…" and dropped `isProcessing`
            // mid-load, briefly unpausing the read-ahead loop. Every other early-out in this
            // method already guards the same way; the catch was the one that didn't.
            guard imageURL == url else { return }
            statusMessage = "Couldn't read that photo — \(error.localizedDescription)"
        }
        guard imageURL == url else { return }
        isProcessing = false
        // The photo is on screen and nobody is waiting: read its neighbors, so the next arrow
        // key meets a frame that is already read. Bounded and re-seeded per move — see
        // `seedNeighborhoodRead`.
        seedNeighborhoodRead()
    }

    func selectCandidate(id: String) {
        guard let candidate = candidates.first(where: { $0.id == id }) else { return }
        selectedCandidateId = id
        showingOriginal = false          // never leave the before/after compare stuck on
        straighten = 0; hsl = [:]; activeLookId = nil
        // Load the candidate's actual values into the editable set — the user edits from here.
        edit = candidate.baseRecipe.global
        editBaseline = candidate.baseRecipe.global
        baseMasks = candidate.baseRecipe.masks ?? []
        maskEnabled = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, true) })
        maskStrength = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, $0.opacity * 100) })
        maskAdjustments = [:]; maskFeather = [:]; maskInvert = [:]
        maskTightness = [:]      // omitted here while `resetMask` cleared it — a slip, not a policy
        updateActiveRecipe()
        resetHistory()          // the chosen candidate is the new base for undo
        // NOTE: selecting/browsing candidates does NOT record a pick — only a deliberate
        // choice (export) does. Recording on every selection floods the store with fake
        // preferences and corrupts the learned profile.
    }

    /// Revert every manual edit back to the candidate as Kelvin generated it.
    func resetToCandidate() {
        edit = editBaseline
        straighten = 0
        hsl = [:]
        activeLookId = nil
        maskEnabled = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, true) })
        maskStrength = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, $0.opacity * 100) })
        maskAdjustments = [:]; maskFeather = [:]; maskInvert = [:]
        maskTightness = [:]      // omitted here while `resetMask` cleared it — a slip, not a policy
        updateActiveRecipe()
    }

    func selectCandidateIndex(_ index: Int) {
        guard index >= 0, index < candidates.count else { return }
        selectCandidate(id: candidates[index].id)
        // Choosing ends the comparison. A number key pressed while comparing is the same decision a
        // click on a tile is, and leaving the grid up afterwards would make the app look like it
        // had not heard.
        comparing = false
    }

    // MARK: Comparing candidates

    /// Whether the compare grid has the canvas.
    var comparing = false
    /// Two at a time or all four. Remembered for the session — someone who wants the survey wants
    /// it on the next frame too — but not persisted, because it is a way of looking rather than a
    /// setting.
    var compareMode: CandidateCompare.Mode = .two
    /// What the chosen candidate is being held against in 2-up. Nil means "the next one".
    var comparePartnerId: String?
    /// Canvas-resolution renders, keyed by candidate id.
    ///
    /// The picker's own thumbnails are 768 px because at 62 points that is ample; shown a foot wide
    /// they are not, and the whole point of this view is that the difference should be visible. So
    /// the candidates are re-rendered once, on the proxy the canvas itself draws, through the same
    /// `Renderer` call — a comparison of anything other than what you would actually get is worse
    /// than no comparison.
    private(set) var compareRenders: [String: NSImage] = [:]
    /// Guards a render batch against the photograph moving on under it, exactly like the candidate
    /// build it mirrors.
    @ObservationIgnored private var compareRenderToken = 0

    /// Comparing needs two things to compare and a proxy to draw them from.
    var canCompare: Bool { candidates.count >= 2 && proxyCI != nil }

    func toggleCompare() {
        if comparing { comparing = false; return }
        guard canCompare else { return }
        if selectedCandidateId == nil { selectedCandidateId = candidates.first?.id }
        comparing = true
        buildCompareRenders()
    }

    func closeCompare() { comparing = false }

    /// The pick, made from the compare view — which is the reason the view exists.
    func pickFromCompare(id: String) {
        selectCandidate(id: id)
        comparing = false
    }

    /// Render every curated candidate at proxy resolution, off the main actor.
    ///
    /// Four renders of a 1200 px proxy, measured at roughly 20 ms each on this machine, so the grid
    /// is soft for about a tenth of a second and then sharp. Deliberately NOT done when the
    /// candidates are built: most photographs are never compared, and paying for four extra renders
    /// on every frame of a 400-frame shoot to serve the ones that are is the wrong trade.
    private func buildCompareRenders() {
        guard let proxy = proxyCI else { return }
        let items = candidates.map { (id: $0.id, recipe: $0.baseRecipe) }
        let masks = proxyMaskBitmaps
        let url = imageURL
        compareRenderToken += 1
        let token = compareRenderToken
        Task { [weak self] in
            let rendered = await Offload.run(.render) { () -> CompareRenders in
                var out: [String: NSImage] = [:]
                for item in items {
                    let ci = Renderer.render(proxy, with: item.recipe, maskBitmaps: masks)
                    if let cg = AppState.sharedContext.createCGImage(ci, from: ci.extent) {
                        out[item.id] = NSImage(cgImage: cg, size: .zero)
                    }
                }
                return CompareRenders(images: out)
            }
            guard let self, self.compareRenderToken == token, self.imageURL == url else { return }
            self.compareRenders = rendered.images
        }
    }

    /// Boxed for the same reason `CandidateBatch` is: `NSImage` crosses the actor boundary here and
    /// the box is where that is said out loud.
    private struct CompareRenders: @unchecked Sendable {
        let images: [String: NSImage]
    }

    func onEdit() {
        MainWork.time("updateActiveRecipe") { updateActiveRecipe() }
        MainWork.time("scheduleCommit") { scheduleCommit() }
    }

    /// True while a Fix click is still working, so a second click can't start a parallel loop.
    private(set) var fixInProgress = false

    /// Apply a targeted correction for a flagged craft issue — the "Fix" the warning offers.
    ///
    /// One nudge often isn't enough — a badly over-saturated frame needs more than −16 saturation —
    /// so a click nudges more than once. But the nudges are RELATIVE, and an earlier version simply
    /// repeated them while the flag was up, which compounds: on a cat beside a pale pink toy, one
    /// click drove `highlights` to −100 and turned the toy vividly orange. The convergence rules —
    /// an excursion budget, evidence that the nudge is working, and a refusal to clip colour on
    /// the way — live in `CraftFix` in Core, where they are tested against the real renderer.
    ///
    /// The loop runs off the main thread: it renders and measures the proxy once per pass, and
    /// only the settled result comes back. It used to be driven from `scheduleCommit`, which fires
    /// after *any* edit — so a slider the user dragged afterwards could trigger another nudge.
    func applyFix(_ issue: AestheticEvaluator.Issue) {
        // Subject problems are fixed ON THE SUBJECT, not globally — the frame as a whole is not the
        // problem, the person in it is.
        if CraftFix.subjectStep(for: issue) != nil { applySubjectFix(issue); return }

        guard !fixInProgress, let proxy = proxyCI, let recipe = activeRecipe else { return }
        fixInProgress = true
        let start = edit
        // WHICH PHOTOGRAPH THIS RUN IS ABOUT, captured before the work starts.
        //
        // `CraftFix.converge` renders and measures the proxy once per pass, so it runs for seconds.
        // Every landing site in this file that assigns edit state has to say which photo it was
        // measuring — `loadPhoto` guards three times, renders carry a `renderedURL` — and these fix
        // paths were the ones that did not. Click Fix, arrow to the next frame, and photo A's
        // converged exposure and contrast were written onto photo B and then persisted by
        // `scheduleCommit`. Silent, plausible, and wrong: exactly the bug the sessions cache was
        // built to stop.
        let photo = imageURL
        let input = RenderInput(
            recipe: recipe, proxy: proxy,
            bitmaps: proxyMaskBitmaps
                .merging(brushBitmaps(extent: proxy.extent)) { _, baked in baked }
                .merging(wandBitmaps(extent: proxy.extent, source: proxy)) { _, grown in grown })
        Task.detached(priority: .userInitiated) {
            // On the vision lane: every probe renders and reads Vision. See `Offload`.
            let settled = await Offload.run(.vision) {
                // Vision's face-rectangle detector fires on animals — it reports a face on a cat —
                // so every skin rule would otherwise be applied to fur. The semantic person
                // segmentation answers honestly, and its cost is one click's worth, not one
                // render's.
                let isPerson = SubjectMask.person(in: input.proxy) != nil
                return (try? CraftFix.converge(issue: issue, from: start,
                                               subjectIsPerson: isPerson) { g in
                    var recipe = input.recipe
                    recipe.global = g
                    let rendered = Renderer.render(input.proxy, with: recipe, maskBitmaps: input.bitmaps)
                    return CraftFix.Reading(stats: try ImageStatistics.compute(rendered),
                                            face: FaceSkin.read(in: rendered))
                })?.global
            }
            await MainActor.run {
                // Cleared even when the result is discarded, or the Fix buttons stay wedged on the
                // photograph you moved to.
                self.fixInProgress = false
                guard self.imageURL == photo else { return }
                guard let settled, settled != self.edit else { return }
                self.edit = settled
                self.onEdit()
            }
        }
    }

    /// Resolve every flagged craft issue in one click.
    ///
    /// Not a loop over `applyFix`. The corrections pull against each other — `.flat` adds contrast
    /// while `.crushedShadows` takes it out, `.blownHighlights` narrows the range that `.flat`
    /// complains about — so run in sequence they trade the photograph back and forth, each one
    /// reading as a success on its own metric while it undoes the last. The order, the rule for
    /// which of a contradictory pair wins, and the end-to-end check that throws the whole excursion
    /// away if the frame did not actually improve all live in `CraftFix.fixAll`, in Core, where they
    /// are measured against the real renderer.
    ///
    /// ONE undo step: the settled state is assigned once, so the coalescing commit records a single
    /// entry however many corrections the run applied.
    func applyFixAll() {
        guard !fixInProgress, let proxy = proxyCI, let recipe = activeRecipe else { return }
        fixInProgress = true
        statusMessage = "Working through the craft flags…"
        let start = edit
        let photo = imageURL            // see `applyFix`: this run belongs to one photograph
        let input = RenderInput(
            recipe: recipe, proxy: proxy,
            bitmaps: proxyMaskBitmaps
                .merging(brushBitmaps(extent: proxy.extent)) { _, baked in baked }
                .merging(wandBitmaps(extent: proxy.extent, source: proxy)) { _, grown in grown })
        Task.detached(priority: .userInitiated) {
            let run = await Offload.run(.vision) {
                let isPerson = SubjectMask.person(in: input.proxy) != nil
                return try? CraftFix.fixAll(from: start, subjectIsPerson: isPerson) { g in
                    var recipe = input.recipe
                    recipe.global = g
                    let rendered = Renderer.render(input.proxy, with: recipe, maskBitmaps: input.bitmaps)
                    return CraftFix.Reading(stats: try ImageStatistics.compute(rendered),
                                            face: FaceSkin.read(in: rendered))
                }
            }
            await MainActor.run {
                self.fixInProgress = false
                guard self.imageURL == photo else { return }
                guard let run else {
                    self.statusMessage = "Couldn't measure this photo — nothing changed"
                    return
                }
                if run.global != self.edit {
                    self.edit = run.global
                    self.onEdit()
                }
                self.statusMessage = Self.fixAllStatus(run)
            }
        }
    }

    /// What the run actually achieved, in the status line. It must never claim more than it did:
    /// the flags it could not clear are still on screen with their own Fix buttons, and a run that
    /// handed the photo back untouched says so rather than going quiet and looking successful.
    private static func fixAllStatus(_ run: CraftFix.RunResult) -> String {
        let total = run.resolved.count + run.remaining.count
        switch run.outcome {
        case .nothingToDo:
            return "Nothing flagged — this frame is already clean"
        case .allResolved:
            return "Fixed all \(total) craft flag\(total == 1 ? "" : "s")"
        case .partlyResolved where run.resolved.isEmpty:
            return "Eased what it could · \(run.remaining.count) still flagged"
        case .partlyResolved where run.deferred.count == run.remaining.count:
            // Subject flags are deferred BEFORE any work starts (`deferredForSubject` is intersected
            // with the starting issues), so "they pull against what was fixed" stated a reason the
            // code knows to be false — nothing was tried against them at all.
            return "Fixed \(run.resolved.count) of \(total) · "
                + "\(run.remaining.count) need their own Fix"
        case .partlyResolved:
            return "Fixed \(run.resolved.count) of \(total) · \(run.remaining.count) still flagged"
        case .nothingSafeToDo:
            return "Left as it was — no automatic fix here without breaking something else"
        case .reverted:
            return "Left as it was — every fix cost the photo more than it bought"
        }
    }

    /// One click of a subject fix — `.subjectTooDark`, `.subjectBlown`, `.subjectFlat` — pressed to
    /// the fixed point of the control that corrects it.
    ///
    /// THE BUG THIS EXISTS FOR. This used to apply one fixed nudge per click with nothing measuring
    /// the result: +0.35 EV on the subject mask for `.subjectTooDark`, whatever the photo. On a
    /// backlit portrait that is a sixth of the correction, so the reported behaviour followed
    /// exactly — click, the picture changes, the warning stays; click, it changes again, the
    /// warning stays; and from the seventh click the mask was pinned at its ±2 EV ceiling and the
    /// button did nothing at all while still being offered. The mask itself was working perfectly:
    /// measured, face luma went 0.217 → 0.409 over those six clicks. The nudge was simply the wrong
    /// size and nobody was checking.
    ///
    /// Now the step is SIZED from what is measured (see `CraftFix.subjectStep`) and pressed by
    /// `CraftFix.convergeSubject`, which re-renders and re-measures between passes and stops the
    /// moment the flag clears, the control runs out, or a pass fails to earn its place. One click,
    /// one answer. And when the answer is "this cannot be finished", `canFix` stops offering the
    /// button rather than leaving the user to discover it by clicking.
    ///
    /// Off the main thread, like the global fix: it renders and measures the proxy once per pass.
    private func applySubjectFix(_ issue: AestheticEvaluator.Issue) {
        guard !fixInProgress, let proxy = proxyCI, let recipe = activeRecipe else { return }
        guard hasPerson else {
            // No segmentation, no mask, no control. `adjustSubjectMask` used to return silently
            // here, which is a button that does nothing and does not say why.
            exhaustedFixes.insert(issue)
            statusMessage = "No subject \(Branding.displayName) can isolate in this frame — that one needs a mask you draw"
            return
        }
        // The subject mask the fixes accumulate on. Found (not created) up front, so the loop can
        // measure trial values without mutating anything the user would see.
        let existing = userMasks.first { $0.kind == .subject }
        let maskId = existing?.id ?? UUID()
        let saturation = existing?.saturation ?? 0
        let start = CraftFix.SubjectState(exposureEV: existing?.exposure ?? 0,
                                          contrast: existing?.contrast ?? 0)
        let others = (recipe.masks ?? []).filter { $0.id != maskId.uuidString }
        fixInProgress = true
        // See `applyFix`. This one lands via `adjustSubjectMask`, so without the guard it writes a
        // converged subject exposure into whichever photograph's mask stack happens to be open.
        let photo = imageURL
        let input = RenderInput(
            recipe: recipe, proxy: proxy,
            bitmaps: proxyMaskBitmaps
                .merging(brushBitmaps(extent: proxy.extent)) { _, baked in baked }
                .merging(wandBitmaps(extent: proxy.extent, source: proxy)) { _, grown in grown })
        Task.detached(priority: .userInitiated) {
            let settled = await Offload.run(.vision) {
                try? CraftFix.convergeSubject(issue: issue, from: start) { state in
                    var trial = input.recipe
                    var vm = UserMaskVM(kind: .subject)
                    vm.id = maskId
                    vm.exposure = state.exposureEV
                    vm.contrast = state.contrast
                    vm.saturation = saturation
                    trial.masks = others + [vm.toMask()]
                    let rendered = Renderer.render(input.proxy, with: trial, maskBitmaps: input.bitmaps)
                    return CraftFix.Reading(stats: try ImageStatistics.compute(rendered),
                                            face: FaceSkin.read(in: rendered))
                }
            }
            await MainActor.run {
                self.fixInProgress = false
                guard self.imageURL == photo else { return }
                guard let settled else {
                    self.statusMessage = "Couldn't measure this photo — nothing changed"
                    return
                }
                if settled.passes > 0 {
                    self.adjustSubjectMask { mask in
                        mask.exposure = settled.state.exposureEV
                        mask.contrast = settled.state.contrast
                    }
                    self.onEdit()
                }
                switch settled.outcome {
                case .resolved:
                    self.statusMessage = "Fixed · \(issue.message)"
                case .notFlagged:
                    break
                default:
                    // The control has gone as far as it goes. Record it so the button stops being
                    // offered: a fix that provably cannot finish must say so, not invite a
                    // seventh click.
                    self.exhaustedFixes.insert(issue)
                    self.statusMessage = Self.subjectFixStatus(issue, settled)
                }
            }
        }
    }

    /// What a subject click actually achieved, in the status line — never claiming more than it did.
    private static func subjectFixStatus(_ issue: AestheticEvaluator.Issue,
                                         _ result: CraftFix.SubjectResult) -> String {
        switch result.outcome {
        case .noProgress, .notApplicable:
            return "No automatic fix for \(issue.message) on this frame — the subject controls "
                + "can't move it"
        case .wouldHarm:
            return "Went as far as it could · any further and the subject starts losing detail"
        default:
            return result.passes > 0
                ? "Eased \(issue.message) as far as the subject control goes — still flagged"
                : "The subject control is already at its limit here"
        }
    }

    /// Whether the Fix button should be offered for `issue` at all.
    ///
    /// Global fixes are always offerable — `CraftFix.converge` decides for itself whether a step is
    /// worth taking and hands the photo back untouched if not. The subject family is different: its
    /// controls have hard ceilings (±2 EV, ±30 contrast), and a mask already sitting on one has
    /// nothing left to give however many times the button is pressed. Asked of the CURRENT
    /// measurement rather than cached, so a user who pulls the subject exposure back down gets the
    /// button back.
    func canFix(_ issue: AestheticEvaluator.Issue) -> Bool {
        guard CraftFix.subjectStep(for: issue) != nil else { return true }
        guard hasPerson, !exhaustedFixes.contains(issue), let reading = lastCraftReading else {
            return false
        }
        let mask = userMasks.first { $0.kind == .subject }
        return CraftFix.subjectStep(for: issue, reading: reading,
                                    exposureEV: mask?.exposure ?? 0,
                                    contrast: mask?.contrast ?? 0) != nil
    }

    /// Find the subject mask, creating one if this is the first subject fix, and adjust it.
    /// Repeated fixes accumulate on the same mask rather than stacking up duplicates.
    private func adjustSubjectMask(_ change: (inout UserMaskVM) -> Void) {
        guard hasPerson else { return }     // nothing to act on; the flag will simply persist
        if let i = userMasks.firstIndex(where: { $0.kind == .subject }) {
            change(&userMasks[i])
        } else {
            var m = UserMaskVM(kind: .subject)
            m.exposure = 0                  // start neutral; the change below supplies the amount
            change(&m)
            userMasks.append(m)
        }
    }

    /// Apply a creative look on top of the current candidate — or clear it with nil. Looks are
    /// deltas on the candidate's baseline, so switching between them never compounds: each one is
    /// applied to the untouched baseline rather than to whatever the last look left behind.
    func applyLook(_ id: String?) {
        activeLookId = id
        var g = editBaseline
        if let id, let look = LookPreset.named(id) {
            look.apply(to: &g)
            // ONLY when the look actually carries one. `hsl = look.hsl ?? [:]` wiped hand-tuned
            // per-band colour on every look tap — and most looks carry no `hsl` at all, so
            // choosing any of them silently discarded work in a panel the user was not looking at.
            // Clearing the look does the same. Undoable, but nothing said it had happened.
            if let lookHSL = look.hsl { hsl = lookHSL }
        }
        edit = g
        onEdit()
    }

    /// The active look, resolved from the library. Its structured limbs (mono, curve) are
    /// folded into the rendered recipe by `updateActiveRecipe`.
    private var activeLook: LookPreset? {
        activeLookId.flatMap { LookPreset.named($0) }
    }

    /// Level the horizon automatically (Vision). No-op if no clear horizon is found.
    func autoStraighten() {
        // Vision, off the actor. `HorizonDetector` performs a `VNDetectHorizonRequest`, and this
        // ran it synchronously on `@MainActor` — the same class of freeze as export and batch, just
        // shorter, so it read as the button being slow rather than as the window being blocked.
        guard let proxy = proxyCI else { return }
        let input = ImageBox(image: proxy)
        let photo = imageURL            // see `applyFix`: a horizon belongs to one photograph
        Task { [weak self] in
            let deg = await Offload.run(.vision) {
                HorizonDetector.levelingAngle(in: input.image)
            }
            guard let self, self.imageURL == photo else { return }
            // EVERY outcome says something. This returned silently when no horizon was found and
            // rotated by ~0° when the frame was already level — two different kinds of nothing,
            // both indistinguishable from a broken button. Reported as exactly that.
            guard let deg else {
                self.statusMessage = "No clear horizon on this frame — drag Straighten by eye instead"
                return
            }
            let target = min(15, max(-15, deg))
            if abs(target - self.straighten) < 0.05 {
                self.statusMessage = abs(target) < 0.05
                    ? "Already level — no rotation needed"
                    : String(format: "Already levelled at %+.1f° — nothing to change", target)
                return
            }
            self.straighten = target
            self.onEdit()
            self.statusMessage = String(format: "Levelled — rotated %+.1f°", target)
        }
    }

    /// A `CIImage` on its way to a detached task. Boxed to say the crossing is deliberate.
    private struct ImageBox: @unchecked Sendable { let image: CIImage }

    // MARK: Undo / redo (coalesced edit history)

    var canUndo = false
    var canRedo = false
    @ObservationIgnored private var undoStack: [EditSnapshot] = []
    @ObservationIgnored private var redoStack: [EditSnapshot] = []
    @ObservationIgnored private var committed: EditSnapshot?
    @ObservationIgnored private var commitToken = 0

    private func snapshot() -> EditSnapshot {
        EditSnapshot(edit: edit, userMasks: userMasks, maskEnabled: maskEnabled,
                     maskStrength: maskStrength, straighten: straighten, hsl: hsl,
                     healSpots: healSpots)
    }
    private func applySnapshot(_ s: EditSnapshot) {
        edit = s.edit; userMasks = s.userMasks; maskEnabled = s.maskEnabled
        maskStrength = s.maskStrength; straighten = s.straighten; hsl = s.hsl
        healSpots = s.healSpots
        updateActiveRecipe()
    }
    /// Reset the history to the current state — call when a fresh candidate/photo becomes the base.
    /// A new base also re-opens the question of which fixes are reachable, so anything a subject
    /// fix gave up on is forgotten here rather than following the user to the next photograph.
    func resetHistory() {
        undoStack = []; redoStack = []; committed = snapshot(); exhaustedFixes = []
        refreshUndoState()
    }

    /// After an edit burst settles (~0.45 s of no further edits), record the prior stable state as
    /// one undo step — so dragging a slider is a single undo, not hundreds.
    private func scheduleCommit() {
        commitToken += 1
        let t = commitToken
        // WHOSE edit this is, decided now rather than in 0.45 s. Keyed on `imageURL`, a commit
        // scheduled for one photograph and landing after a switch wrote that photograph's numbers
        // under the next one's name — or, if the state had been cleared in between, read as
        // untouched and deleted the next one's saved edit. `loadedURL` is the ownership boundary
        // (see its doc); it moves only when a decode lands or a cached session is restored.
        let owner = loadedURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.commitToken == t, self.loadedURL == owner else { return }
            if let prev = self.committed, prev != self.snapshot() {
                self.undoStack.append(prev)
                if self.undoStack.count > 60 { self.undoStack.removeFirst() }
                self.redoStack.removeAll()
            }
            self.committed = self.snapshot()
            self.refreshUndoState()
            // Keep the filmstrip's "edited" dot honest as you work, not just on switch, and put
            // the edit on disk so quitting the app doesn't throw the work away.
            if let url = owner {
                if self.isTouched { self.editedURLs.insert(url) } else { self.editedURLs.remove(url) }
                self.persistEdit(for: url)
            }
        }
    }
    private func refreshUndoState() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }

    /// Commit the current state as an undo step *now*, instead of when the edit burst settles.
    ///
    /// The 0.45 s coalescing exists so dragging a slider is one undo rather than hundreds. A
    /// discrete click is the opposite case: two heals a quarter-second apart are two decisions, and
    /// merging them means one ⌘Z removes a spot the user did not ask it to. Bumping `commitToken`
    /// cancels whatever coalesced commit was already pending.
    private func commitNow() {
        commitToken += 1
        if let prev = committed, prev != snapshot() {
            undoStack.append(prev)
            if undoStack.count > 60 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        committed = snapshot()
        refreshUndoState()
        if let url = imageURL {
            if isTouched { editedURLs.insert(url) } else { editedURLs.remove(url) }
            persistEdit(for: url)
        }
    }

    /// Re-render and record one undo step, for edits that arrive as discrete clicks rather than
    /// as a drag. See `commitNow`.
    func onDiscreteEdit() {
        updateActiveRecipe()
        commitNow()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshot()); committed = prev
        applySnapshot(prev); refreshUndoState()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot()); committed = next
        applySnapshot(next); refreshUndoState()
    }

    /// Which brush mask is currently being painted (drag on the preview paints into it), and the
    /// brush size (fraction of the smaller edge).
    var paintingMaskId: UUID?
    var brushRadius = 0.09
    /// The user mask being edited ON THE CANVAS (drag its handles to move/size it).
    /// WHICH MASK IS BEING WORKED ON — auto (subject/sky) or hand-drawn, one selection covering
    /// both. It used to be `selectedUserMaskId: UUID?`, which could only ever name a hand-drawn
    /// mask, and that single gap produced the reported bug: the sky came up covered in red that
    /// you could not edit or dismiss.
    ///
    /// What actually happened is that with nothing selected, the overlay fell back to "the first
    /// enabled auto mask" and drew it. So the red was not the sky mask being ON, it was the
    /// overlay GUESSING — and since an auto mask could not be selected, there was no way to edit
    /// the thing you were looking at, and no way to deselect it to make the red go away. An
    /// overlay that shows something the selection model cannot name is an overlay with no off
    /// switch.
    enum MaskRef: Equatable {
        case auto(String)       // "subject", "sky" — the engine's own masks
        case user(UUID)         // anything hand-drawn or picked from the subject list
    }
    var selectedMask: MaskRef?

    /// The hand-drawn selection, for the call sites that only make sense for one (canvas handles,
    /// brush painting). Setting it selects; reading it yields nil when an auto mask is selected.
    var selectedUserMaskId: UUID? {
        get { if case .user(let id) = selectedMask { return id } else { return nil } }
        set { selectedMask = newValue.map { .user($0) } }
    }

    /// Show me this mask — or, if it is already the one being shown, put the selection down.
    ///
    /// The other half of the same reported bug. Selecting a hand-drawn mask assigned
    /// unconditionally, so a selection could be moved to another mask but never cleared, and
    /// everything the canvas draws for the selected mask (a subject's outline, a gradient's
    /// handles) stayed until the mask was DELETED. Reaching for the trash to dismiss an annotation
    /// is how a photographer loses the adjustments they just made.
    ///
    /// Auto masks have toggled since the day they became selectable, for this exact reason. This is
    /// the same rule for the other half of the panel.
    func toggleMaskSelection(_ id: UUID) {
        if selectedUserMaskId == id {
            selectedMask = nil
            // With nothing selected the overlay draws nothing, so a still-armed brush would be
            // painting strokes the canvas has stopped showing. Putting the mask down puts the
            // brush down.
            if paintingMaskId == id { paintingMaskId = nil }
        } else {
            selectedUserMaskId = id
        }
        // Rebuilds the render, which is what chooses the overlay bitmap. Without it the red stays
        // on the mask that is no longer selected.
        onEdit()
    }

    // MARK: Canvas coordinate mapping (view ⇄ normalised image space)

    /// The geometry currently applied to the preview (nil when the photo isn't straightened).
    var activeGeometry: Geometry? {
        straighten != 0 ? Geometry(rotateDeg: straighten, crop: nil, lensCorrection: false) : nil
    }

    /// The extent of the image AS DISPLAYED — after straighten/crop. The preview shows the framed
    /// result, so the letterbox must use its aspect, not the uncropped source's.
    private var framedExtent: CGRect {
        guard let proxy = proxyCI else { return .zero }
        guard straighten != 0 else { return proxy.extent }
        return Renderer.largestInscribedRect(proxy.extent, angleDeg: straighten)
    }

    /// The rectangle the image actually occupies inside the padded preview area, accounting for
    /// the current zoom + pan — so on-canvas masks and brush strokes stay aligned when zoomed.
    func imageRect(in container: CGSize, pad: CGFloat = 24) -> CGRect {
        let availW = container.width - 2 * pad, availH = container.height - 2 * pad
        let framed = framedExtent
        guard framed.width > 0, framed.height > 0, availW > 0, availH > 0 else { return .zero }
        let aspect = framed.width / framed.height
        var w = availW, h = availH
        if aspect > availW / availH { h = availW / aspect } else { w = availH * aspect }
        w *= zoom; h *= zoom
        let cx = container.width / 2 + pan.width
        let cy = container.height / 2 + pan.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    func resetZoom() { zoom = 1; pan = .zero }

    /// Space: back and forth between fitted and the last magnification used, which is how every
    /// other editor's spacebar behaves. Remembering the ratio matters — a zoom toggle that always
    /// returned to 2× would lose the 6× someone was inspecting focus at.
    private(set) var lastZoomRatio: Double = 2
    func toggleZoomRatio() {
        if zoom > 1.01 { lastZoomRatio = zoom; setZoom(1) } else { setZoom(lastZoomRatio) }
    }

    /// `U`: clear whatever decision this frame carries. `FlagStore.toggle` clears by re-applying the
    /// same flag, so the honest way to unflag is to ask what it has and repeat it.
    func clearFlagOnCurrent() {
        guard let url = imageURL, let current = flags[url] else { return }
        setFlag(current, for: url)
    }

    /// `/`: fold the strip away, or bring it back. Written through `FilmstripFold` so that using the
    /// key counts as a decision exactly as clicking the control does — otherwise the next photo
    /// opened would quietly overrule it.
    func toggleFilmstrip() {
        let now = UserDefaults.standard.bool(forKey: FilmstripFold.expandedKey)
        FilmstripFold.recordUserChoice(expanded: !now)
    }

    /// `⌘I`: invert whichever mask is selected, auto or hand-drawn.
    func invertSelectedMask() {
        switch selectedMask {
        case .auto(let id):
            maskInvert[id] = !(maskInvert[id] ?? false)
        case .user(let id):
            guard let i = userMasks.firstIndex(where: { $0.id == id }) else { return }
            userMasks[i].invert.toggle()
        case nil:
            return
        }
        onEdit()
    }

    /// `⇧]` / `⇧[`: soften or harden the selected mask's edge.
    func adjustSelectedFeather(by delta: Double) {
        func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
        switch selectedMask {
        case .auto(let id):
            let current = maskFeather[id] ?? baseMasks.first { $0.id == id }?.feather ?? 0
            maskFeather[id] = clamp(current + delta)
        case .user(let id):
            guard let i = userMasks.firstIndex(where: { $0.id == id }) else { return }
            userMasks[i].feather = clamp(userMasks[i].feather + delta)
        case nil:
            return
        }
        onEdit()
    }
    func setZoom(_ z: Double) { zoom = min(8, max(1, z)); if zoom == 1 { pan = .zero } }
    /// Mask coordinates are stored in SOURCE space (masks are applied before geometry), while the
    /// preview shows the FRAMED image — so both directions route through the renderer's geometry
    /// transform. Without this a mask placed on a straightened photo lands offset.
    func normToView(_ nx: Double, _ ny: Double, in rect: CGRect) -> CGPoint {
        let f = Renderer.framedNormalized(fromSource: CGPoint(x: nx, y: ny),
                                          geometry: activeGeometry,
                                          sourceExtent: proxyCI?.extent ?? .zero)
        return CGPoint(x: rect.minX + f.x * rect.width, y: rect.minY + f.y * rect.height)
    }
    func viewToNorm(_ p: CGPoint, in rect: CGRect) -> (Double, Double) {
        guard rect.width > 0, rect.height > 0 else { return (0.5, 0.5) }
        let framed = CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
        let s = Renderer.sourceNormalized(fromFramed: framed, geometry: activeGeometry,
                                          sourceExtent: proxyCI?.extent ?? .zero)
        return (Double(s.x), Double(s.y))
    }

    private func withMask(_ id: UUID, _ body: (inout UserMaskVM) -> Void) {
        guard let i = userMasks.firstIndex(where: { $0.id == id }) else { return }
        body(&userMasks[i]); onEdit()
    }
    func moveMask(_ id: UUID, to nx: Double, _ ny: Double) {
        withMask(id) { $0.cx = min(1, max(0, nx)); $0.cy = min(1, max(0, ny)) }
    }
    /// Resize a radial mask so its edge passes through the dragged point.
    func resizeRadial(_ id: UUID, edgeAt p: CGPoint, in rect: CGRect) {
        guard let m = userMasks.first(where: { $0.id == id }) else { return }
        let c = normToView(m.cx, m.cy, in: rect)
        let distPx = ((p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y)).squareRoot()
        // The drag is measured against the FRAMED image on screen, but `radius` is a fraction of
        // the SOURCE image's short edge (masks live in source space) — rescale when cropped.
        let frac = distPx / min(rect.width, rect.height)
        withMask(id) { $0.radius = min(1.2, max(0.05, Double(frac) * framedToSourceScale)) }
    }

    /// How much smaller the framed (post-straighten, post-crop) image is than the source, on its
    /// short edge. One definition, because the resize and the drawing must agree: they did not,
    /// and the circle disagreed with the effect by about 23% at 15° of straighten.
    var framedToSourceScale: Double {
        let framed = framedExtent, source = proxyCI?.extent ?? framed
        guard min(source.width, source.height) > 0 else { return 1 }
        return Double(min(framed.width, framed.height) / min(source.width, source.height))
    }
    /// Rotate a linear mask so its gradient direction points at the dragged handle.
    func rotateLinear(_ id: UUID, handleAt p: CGPoint, in rect: CGRect) {
        guard let m = userMasks.first(where: { $0.id == id }) else { return }
        let c = normToView(m.cx, m.cy, in: rect)
        let ang = atan2(p.x - c.x, -(p.y - c.y)) * 180 / .pi   // 0° = up
        withMask(id) { $0.angle = (ang < 0 ? ang + 360 : ang) }
    }

    /// The user's saved mask presets, loaded once and written through on every change.
    var customMaskPresets: [MaskPreset] = MaskPresetStore.load()

    /// Start a mask from a preset — an ordinary mask wearing the preset's settings and name.
    func addPresetMask(_ preset: MaskPreset) {
        let m = preset.instantiate()
        userMasks.append(m)
        selectedUserMaskId = m.id
        showMaskOverlay = true
        onEdit()
        statusMessage = "\(preset.name) added — tune it like any other mask"
    }

    /// Name and keep the current mask's settings. An AppKit alert rather than a SwiftUI sheet for
    /// the same reason the panel accessories are AppKit: it is modal, tiny, and needs a first
    /// responder, and that is what NSAlert is for.
    func promptSaveMaskPreset(_ mask: UserMaskVM) {
        guard MaskPreset.isCapturable(mask.kind) else { return }
        let alert = NSAlert()
        alert.messageText = "Save as preset"
        alert.informativeText = "These settings become a reusable starting point in the preset "
            + "menu, stored on this Mac."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = mask.name ?? ""
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            statusMessage = "A preset needs a name — nothing was saved"
            return
        }
        customMaskPresets.append(.capturing(mask, name: name))
        MaskPresetStore.save(customMaskPresets)
        statusMessage = "Saved “\(name)” — it's in the preset menu now"
    }

    func deleteMaskPreset(_ id: UUID) {
        guard let removed = customMaskPresets.first(where: { $0.id == id }) else { return }
        customMaskPresets.removeAll { $0.id == id }
        MaskPresetStore.save(customMaskPresets)
        statusMessage = "Removed the “\(removed.name)” preset"
    }

    /// Add a hand-drawn gradient mask, centred, with a gentle starting darken so the user sees it.
    func addUserMask(_ kind: UserMaskVM.Kind) {
        var m = UserMaskVM(kind: kind)
        m.exposure = -0.6
        if kind == .colorRange { m.selCenter = 0.0; m.selRange = 0.1 }    // reds by default
        if kind == .luminance { m.selCenter = 0.78; m.selRange = 0.2 }    // highlights by default
        if kind == .skin { m.selCenter = 0.06; m.selRange = 0.06; m.selSoftness = 0.05; m.exposure = 0.3 }
        if kind == .background { m.exposure = -0.5 }   // darken the background by default
        if kind == .subject { m.exposure = 0.3 }
        userMasks.append(m)
        selectedUserMaskId = m.id                      // show its canvas handles
        // Shown once, on CREATION only. A mask you cannot see when it appears looks broken —
        // but re-selecting an existing one used to turn the overlay back on too, which is why it
        // felt like it could not be dismissed. Turn it off and it stays off until you make
        // another mask.
        showMaskOverlay = true
        if kind == .brush { paintingMaskId = m.id }    // brush: start painting right away
        // Same idea for the wand, and it matters more: an unseeded wand defaults to the middle of
        // the frame, so it would appear having already grabbed whatever happens to be at dead
        // centre. Arming it means the first thing that happens is the photographer pointing.
        if kind == .wand { seedingMaskId = m.id }
        onEdit()
    }

    /// Move a mask up or down the stack.
    ///
    /// Order is not cosmetic: `activeMasks()` hands the renderer the array as it stands and each
    /// mask composites over the result of the ones before it, so two overlapping masks give a
    /// different photograph depending which is on top. The stack was therefore already meaningful
    /// and simply not adjustable — you got creation order and nothing else.
    func moveUserMask(_ id: UUID, by offset: Int) {
        guard let i = userMasks.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard j >= 0, j < userMasks.count else { return }
        userMasks.swapAt(i, j)
        onEdit()
    }

    func removeUserMask(_ id: UUID) {
        userMasks.removeAll { $0.id == id }
        if paintingMaskId == id { paintingMaskId = nil }
        onEdit()
    }

    /// The Binding a mask card edits through — by IDENTITY, never by position.
    ///
    /// `ForEach($userMasks)`'s element bindings are index-backed, and a TextField flushing a
    /// pending rename in the same layout pass that removed its mask read `userMasks[i]` out of
    /// bounds — an EXC_BREAKPOINT in the owner's first minutes with the build (SystemTextField's
    /// value action fires during NSHostingView.layout, after the delete has landed). By identity,
    /// a read of a departed mask serves the caller's fallback copy — harmless, the card is on its
    /// way out — and a write to one is dropped rather than trapped on.
    ///
    /// `assumeIsolated`, not a hop: Bindings are only ever touched on the main thread, and the
    /// closures themselves are nonisolated — the same shape, for the same reason, as the save
    /// panel's name correction.
    nonisolated func userMaskBinding(fallback m: UserMaskVM) -> Binding<UserMaskVM> {
        Binding(
            get: { MainActor.assumeIsolated {
                self.userMasks.first(where: { $0.id == m.id }) ?? m
            } },
            set: { new in MainActor.assumeIsolated {
                guard let i = self.userMasks.firstIndex(where: { $0.id == m.id }) else { return }
                self.userMasks[i] = new
            } })
    }

    func clearStrokes(_ id: UUID) {
        guard let i = userMasks.firstIndex(where: { $0.id == id }) else { return }
        userMasks[i].stamps = []; onEdit()
    }

    /// Paint a brush dab at a point in the preview area. `loc` is in the preview view's coordinate
    /// space (which is padded by `pad`); we back out the aspect-fit letterboxing to get normalised
    /// image coordinates, then drop a stamp. Throttled by distance so a stroke isn't thousands of
    /// stamps.
    func paintAt(_ loc: CGPoint, container: CGSize, pad: CGFloat = 24) {
        guard let pid = paintingMaskId,
              let idx = userMasks.firstIndex(where: { $0.id == pid }) else { return }
        // Use the SHARED mapping so painting honours zoom, pan, and straighten exactly like the
        // on-canvas handles do. (It used to do its own letterbox math and ignored all three.)
        let rect = imageRect(in: container, pad: pad)
        guard rect.width > 0, rect.height > 0 else { return }
        let framedX = (loc.x - rect.minX) / rect.width
        let framedY = (loc.y - rect.minY) / rect.height
        guard framedX >= 0, framedX <= 1, framedY >= 0, framedY <= 1 else { return }
        let (nx, ny) = viewToNorm(loc, in: rect)
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return }
        // Spacing between dabs: about a third of the brush radius, so consecutive stamps overlap
        // heavily and their soft edges union into one continuous shape. Scaled by zoom, since a
        // screen-inch covers less of the image the further in you are.
        let minStep = brushRadius * 0.33 / max(1, zoom)

        // Round to 4 decimals: sub-pixel even on a 9504 px export, and it keeps the sidecar (and
        // every undo snapshot) compact — stamps are the one recipe field that grows with use.
        func r4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        func stamp(_ x: Double, _ y: Double) {
            userMasks[idx].stamps.append(
                BrushStamp(x: r4(x), y: r4(y), radius: r4(brushRadius), hardness: 0.6,
                           erase: brushErases))
        }

        guard let last = userMasks[idx].stamps.last else {
            stamp(nx, ny); onEdit(); return
        }

        // THE STROKE IS INTERPOLATED, and this is what "the brush adds rough dots" was. A drag
        // gesture reports a position per screen refresh, so a quick stroke can travel several brush
        // widths between two reports. The old code stamped only where the pointer WAS and threw away
        // anything closer than one step — which correctly avoided piling dabs on one spot, and did
        // nothing at all about the gaps between distant ones. Paint slowly and it looked continuous;
        // paint at any speed and it was a row of discs.
        //
        // So walk the line from the previous dab to this one, placing a dab every step. The throttle
        // survives as the first case below: nearer than one step, there is nothing to add.
        let dx = nx - last.x, dy = ny - last.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < minStep { return }

        // Bounded. A pointer that jumps the width of the image — a stylus lifted and set down, or a
        // window dragged across a second display — must not enqueue thousands of dabs and stall the
        // bake. Past the cap the stroke is left broken, which is honest and recoverable, where a
        // frozen app is neither.
        let steps = min(64, max(1, Int((distance / minStep).rounded(.down))))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            stamp(last.x + dx * t, last.y + dy * t)
        }
        onEdit()
    }

    /// The masks to render: the candidate's masks (minus any switched off, scaled to strength),
    /// plus the user's hand-drawn gradient masks.
    private func activeMasks() -> [Mask]? {
        var ms = baseMasks.compactMap { m -> Mask? in
            guard maskEnabled[m.id] ?? true else { return nil }
            var m = m
            m.opacity = Self.clampStep((maskStrength[m.id] ?? m.opacity * 100) / 100, 0...1, 0.01)
            // Whatever the user has dialled in for this mask overrides the engine's proposal.
            // Absent = untouched, so the engine's own values stand.
            if let edited = maskAdjustments[m.id] { m.adjustments = edited }
            if let f = maskFeather[m.id] { m.feather = f }
            if let t = maskTightness[m.id] { m.tightness = t }
            if let inv = maskInvert[m.id] { m.invert = inv }
            return m
        }
        ms += userMasks.map { $0.toMask() }
        return ms.isEmpty ? nil : ms
    }

    private func activeSelectedMaskBitmap(extent: CGRect) -> (bitmap: CIImage, invert: Bool, feather: Double, tightness: Double)? {
        var bitmaps = proxyMaskBitmaps.merging(brushBitmaps(extent: extent)) { _, baked in baked }
        if let proxy = proxyCI {
            bitmaps.merge(wandBitmaps(extent: extent, source: proxy)) { _, grown in grown }
        }
        if let mid = selectedUserMaskId, let userMask = userMasks.first(where: { $0.id == mid }) {
            let maskStruct = userMask.toMask()
            var bitmap: CIImage? = nil
            if let stamps = maskStruct.stamps, !stamps.isEmpty {
                bitmap = bitmaps[maskStruct.id] ?? Renderer.brushMask(stamps, extent: extent)
            } else if let shape = maskStruct.shape {
                bitmap = Renderer.gradientMask(shape, extent: extent)
            } else if let sel = maskStruct.selection, let cube = SelectionMask.makeData(sel) {
                bitmap = (proxyCI ?? CIImage()).applyingFilter("CIColorCubeWithColorSpace", parameters: [
                    "inputCubeDimension": SelectionMask.dimension,
                    "inputCubeData": cube,
                    "inputColorSpace": ImageWriter.outputColorSpace
                ]).cropped(to: extent)
            } else if let seed = maskStruct.region {
                bitmap = bitmaps[maskStruct.id]
                    ?? RegionGrow.mask(in: proxyCI ?? CIImage(),
                                       seed: CGPoint(x: seed.x, y: seed.y),
                                       tolerance: seed.tolerance, softness: seed.softness)
            } else {
                bitmap = bitmaps[maskStruct.id] ?? bitmaps[maskStruct.type]
            }
            if var b = bitmap {
                // The red must show what the mask will EDIT. The renderer narrows a refined mask
                // (skin = the subject ∩ skin hues) before applying its adjustments — but this
                // overlay skipped the refinement, so a Skin mask painted the entire person and was
                // reported as "the same as the person mask". The pixels it edited were right all
                // along; the pixels it CLAIMED were wrong.
                if let refine = maskStruct.refine, let cube = SelectionMask.makeData(refine),
                   let proxy = proxyCI {
                    let selected = proxy.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                        "inputCubeDimension": SelectionMask.dimension,
                        "inputCubeData": cube,
                        "inputColorSpace": ImageWriter.outputColorSpace
                    ]).cropped(to: extent)
                    b = selected.applyingFilter("CIMultiplyCompositing", parameters: [
                        kCIInputBackgroundImageKey: b])
                }
                return (b, maskStruct.invert, maskStruct.feather, maskStruct.tightness ?? 0)
            }
        }
        // An AUTO mask, now that the selection can name one.
        if case .auto(let id) = selectedMask, let b = proxyMaskBitmaps[id] {
            return (b, maskInvert[id] ?? false, maskFeather[id] ?? 0, maskTightness[id] ?? 0)
        }
        // NO FALLBACK, deliberately. This used to answer "the first enabled auto mask" and then
        // "the first hand-drawn one" when nothing was selected, which is how the sky ended up
        // covered in red that nothing could edit and nothing could turn off. Nothing selected now
        // means nothing drawn, so the overlay always answers to something the user can point at.
        return nil
    }

    /// The scene read currently in flight, so opening a newer photo can cancel it. See the
    /// perceive site in `loadPhoto` — an actor queues reads, and only cancellation stops an
    /// abandoned one from spending real seconds ahead of the photo on screen.
    @ObservationIgnored private var perceiveTask: Task<Perception, Error>?

    /// The content hash being computed in the background, so the two things that actually want it can
    /// wait for it rather than record a blank. See the deferred hash in `loadPhoto`.
    @ObservationIgnored private var hashTask: Task<Void, Never>?

    /// The photograph's `sha256:…` identity, waiting for the background hash if it is still running.
    ///
    /// Only ever awaited from inside a `Task` that is already off the critical path — recording a
    /// pick, saving an edit. Never from anything that draws.
    private func resolvedImageId() async -> String? {
        if !imageId.isEmpty { return imageId }
        await hashTask?.value
        return imageId.isEmpty ? nil : imageId
    }

    /// The last rendered proxy (for the histogram + the debounced craft check). Lives on
    /// `preview` for the reason given there.
    @ObservationIgnored private var craftToken = 0

    /// Baked brush strokes, keyed by mask id, with the stamp count they were baked at. Compositing
    /// a long stroke costs O(stamps) *per render* (18 ms at 1200 stamps — worse than the whole rest
    /// of the pipeline), so it's flattened to a concrete bitmap once and reused until it changes.
    @ObservationIgnored private var brushCache: [UUID: (count: Int, image: CIImage)] = [:]

    /// Pre-baked preview bitmaps for the user's brush masks, to hand the renderer.
    /// Grown wand regions, keyed by mask id, with the seed they were grown from.
    ///
    /// The renderer can regrow a wand from its seed alone — it has to, or the mask would be missing
    /// from every export — but doing that on every render means a flood fill per frame of a slider
    /// drag, which is the shape of the problem the brush already had (18 ms per render at 1200
    /// stamps, worse than the whole rest of the pipeline). `Renderer` prefers a supplied bitmap over
    /// regrowing, so the preview hands one over and pays for the fill only when the seed or the
    /// tolerance actually changes.
    ///
    /// Keyed on the SEED, not a counter: the two things that change it are a click and a tolerance
    /// drag, and both must invalidate. Note this is by analogy with the brush's measured cost rather
    /// than a fresh measurement of the fill — if the wand ever feels slow, measure before tuning.
    @ObservationIgnored private var wandCache: [UUID: (seed: RegionSeed, image: CIImage)] = [:]

    /// Pre-grown regions for the user's wand masks, to hand the renderer.
    /// The wand masks, grown. Pure for the same reason as `bakeBrush`.
    nonisolated static func bakeWand(masks: [UserMaskVM], cache: [UUID: (seed: RegionSeed, image: CIImage)],
                                     extent: CGRect, source: CIImage)
        -> (out: [String: CIImage], cache: [UUID: (seed: RegionSeed, image: CIImage)]) {
        var cache = cache
        var out: [String: CIImage] = [:]
        var live = Set<UUID>()
        for m in masks where m.kind == .wand {
            live.insert(m.id)
            let seed = RegionSeed(x: m.cx, y: m.cy, tolerance: m.wandTolerance,
                                  softness: m.wandSoftness)
            if let hit = cache[m.id], hit.seed == seed {
                out[m.id.uuidString] = hit.image
                continue
            }
            // A miss is left OUT of the dictionary rather than cached as an empty image: the
            // renderer then falls through to growing it itself, which on a different extent may
            // well succeed. Caching "nothing" here would make a wand that missed at preview size
            // stay missing at export size.
            guard let grown = RegionGrow.mask(in: source, seed: CGPoint(x: m.cx, y: m.cy),
                                              tolerance: m.wandTolerance,
                                              softness: m.wandSoftness) else { continue }
            let placed = grown.transformed(by: CGAffineTransform(
                scaleX: extent.width / grown.extent.width,
                y: extent.height / grown.extent.height))
            cache[m.id] = (seed, placed)
            out[m.id.uuidString] = placed
        }
        cache = cache.filter { live.contains($0.key) }
        return (out, cache)
    }

    private func wandBitmaps(extent: CGRect, source: CIImage) -> [String: CIImage] {
        let grown = Self.bakeWand(masks: userMasks, cache: wandCache, extent: extent, source: source)
        wandCache = grown.cache
        return grown.out
    }

    /// The brush masks, baked. Pure: the caller's cache in, the updated cache out, so this can
    /// run on the render lane (see `updateActiveRecipe`) as well as on the actor.
    nonisolated static func bakeBrush(masks: [UserMaskVM], cache: [UUID: (count: Int, image: CIImage)],
                                      extent: CGRect, context: CIContext)
        -> (out: [String: CIImage], cache: [UUID: (count: Int, image: CIImage)]) {
        var cache = cache
        var out: [String: CIImage] = [:]
        var live = Set<UUID>()
        for m in masks where m.kind == .brush && !m.stamps.isEmpty {
            live.insert(m.id)
            if let hit = cache[m.id], hit.count == m.stamps.count {
                out[m.id.uuidString] = hit.image
                continue
            }
            // INCREMENTAL. The cache keys on stamp count, so every new dab invalidated it and the
            // WHOLE stroke was re-composited — `Renderer.brushMask` is O(stamps), measured at
            // 18 ms for 1200 of them, and this runs on the main actor from `updateActiveRecipe`.
            // So the cost was 18 ms *per dab* near the end of a long stroke, and the stroke got
            // slower the longer you painted: O(N²) over a gesture, which is the shape of a brush
            // that feels fine for two seconds and then drags.
            //
            // Only the new stamps need compositing, over the bitmap already baked.
            //
            // The new dabs are laid OVER the previous bake by `brushMask` itself rather than
            // composited beside it and unioned afterwards. That union was correct only while every
            // dab added: it takes the max of the two halves, so an erase in the new dabs would be
            // a dark patch in a lighten blend and vanish without trace — the stroke would look
            // right while painting and wrong on the next render, which is the worst way for it to
            // be wrong.
            let baked = cache[m.id]
            let grew = baked.map { m.stamps.count > $0.count } ?? false
            let fresh = grew ? Array(m.stamps.suffix(m.stamps.count - (baked?.count ?? 0))) : m.stamps
            guard let composited = Renderer.brushMask(fresh, extent: extent,
                                                      over: grew ? baked?.image : nil) else { continue }
            guard let cg = context.createCGImage(composited, from: extent) else { continue }
            let flat = CIImage(cgImage: cg)          // concrete — breaks the O(N) filter chain
            cache[m.id] = (m.stamps.count, flat)
            out[m.id.uuidString] = flat
        }
        cache = cache.filter { live.contains($0.key) }   // drop deleted/cleared masks
        return (out, cache)
    }

    private func brushBitmaps(extent: CGRect) -> [String: CIImage] {
        let baked = Self.bakeBrush(masks: userMasks, cache: brushCache, extent: extent, context: context)
        brushCache = baked.cache
        return baked.out
    }

    /// The craft check's inputs, crossing to a background task. Same reasoning as `RenderInput`:
    /// CIImage is documented thread-safe but not Sendable on the SDK CI builds against.
    private struct MeasuredFrame: @unchecked Sendable {
        let image: CIImage
        let condition: Condition?
    }

    /// Moves the thread-safe-but-not-Sendable Core Image inputs across the concurrency boundary.
    /// CIContext/CIImage are documented thread-safe, so this is sound.
    private struct RenderInput: @unchecked Sendable {
        let recipe: Recipe; let proxy: CIImage; let bitmaps: [String: CIImage]
    }
    private struct RenderOutput: @unchecked Sendable {
        let ci: CIImage; let cg: CGImage?
        /// The histogram of those pixels, read where the pixels are. It used to be read in
        /// `HistogramView.body` — a Core Image render, on the main thread, waiting on a GPU that
        /// the preview render and the model were already using. Sampled during an automated drag:
        /// 68% of main-thread time was that wait. The view now draws numbers it is handed.
        let histogram: HistogramView.Reading?
        /// The brush and wand caches as the bake left them — see `MaskBakeInput`.
        let brushCache: [UUID: (count: Int, image: CIImage)]
        let wandCache: [UUID: (seed: RegionSeed, image: CIImage)]
    }
    /// What the render job needs to bake the hand-made masks itself: the masks, the two caches
    /// as they stand, and the segmentation bitmaps to merge them over. Boxed like `RenderInput`.
    private struct MaskBakeInput: @unchecked Sendable {
        let masks: [UserMaskVM]
        let brushCache: [UUID: (count: Int, image: CIImage)]
        let wandCache: [UUID: (seed: RegionSeed, image: CIImage)]
        let base: [String: CIImage]
    }
    /// The two things the detached render captures that the SDK cannot always vouch for: a
    /// CIContext, and the overlay bitmap. Both are Sendable on the macOS 27 SDK and neither is
    /// on the one CI builds against, where capturing them directly makes the closure itself
    /// non-Sendable — which no @preconcurrency import can reach. Boxing them says once, in one
    /// place, what is already true: the context is thread-safe and the bitmap is immutable.
    private struct RenderSideload: @unchecked Sendable {
        let ctx: CIContext
        let overlay: (bitmap: CIImage, invert: Bool, feather: Double, tightness: Double)?
    }
    @ObservationIgnored private var renderInFlight = false
    @ObservationIgnored private var renderDirty = false

    /// Build the recipe (fast, on the main thread — export always sees the latest), then hand the
    /// GPU render + read-back to a background task so the UI thread stays free while you drag. Only
    /// one render runs at a time; newer edits coalesce so we never queue a backlog of stale frames.
    private func updateActiveRecipe() {
        guard let selectedId = selectedCandidateId,
              let candidate = candidates.first(where: { $0.id == selectedId }),
              let proxy = proxyCI else { return }
        var finalRecipe = candidate.baseRecipe
        finalRecipe.global = edit                       // absolute manual values
        finalRecipe.masks = activeMasks()
        finalRecipe.heal = healSpots.isEmpty ? nil : healSpots
        finalRecipe.geometry = straighten != 0
            ? Geometry(rotateDeg: straighten, crop: nil, lensCorrection: false) : nil
        finalRecipe.hsl = hsl.isEmpty ? candidate.baseRecipe.hsl : hsl
        // The look's structured limbs, by the same absolute-if-present rule as
        // `LookPreset.applied(to:)`. Mono is the active look's or none — a look is the only
        // source of a conversion. The curve replaces the candidate's only when the look owns
        // the tone character. The look's `hsl` is deliberately NOT read here: `applyLook`
        // copied it into the editable `hsl` state above, which the user may have tuned since.
        finalRecipe.blackAndWhite = activeLook?.mono
        if let lookCurve = activeLook?.curve { finalRecipe.curve = lookCurve }
        self.activeRecipe = finalRecipe

        if renderInFlight { renderDirty = true; return }
        renderInFlight = true
        // The brush and wand masks are baked INSIDE the render job below, not here. A wand drag
        // re-grows its region on every tick and a brush stroke composites on every dab, and both
        // ran on the main thread in front of the render. They need the masks and their caches,
        // which cross in a box like everything else in the job and come back updated with it.
        let bake = MaskBakeInput(masks: userMasks, brushCache: brushCache, wandCache: wandCache,
                                 base: proxyMaskBitmaps)
        let input = RenderInput(recipe: finalRecipe, proxy: proxy, bitmaps: [:])
        // Which photo these pixels are of. A render started before a photo switch can still land
        // after it; tagged, that frame is ignored instead of being shown under the new photo's name.
        let renderedURL = loadedURL
        // SUPPRESSED WHILE ADJUSTING. The overlay is composited into the preview at 0.6 opacity,
        // so while it is up you are grading a photograph you cannot see — drag Exposure and the
        // red is what changes. Reported exactly that way: "if I use a slider, I can't really tell
        // what has changed".
        //
        // The two things the overlay is for are opposites. Placing a mask needs the shape visible;
        // adjusting one needs the picture visible. So it stays up for the first and gets out of
        // the way for the second, and comes back on its own when you let go.
        let showOverlay = showMaskOverlay && !isAdjustingMaskTone
        let side = RenderSideload(ctx: context,
                                  overlay: showOverlay ? activeSelectedMaskBitmap(extent: proxy.extent) : nil)
        Task.detached(priority: .userInitiated) {
            let renderStart = Date()
            // The render itself is on the render lane at interactive QoS — a slider is being
            // dragged — and this task only waits for it. See `Offload`.
            let out = await Offload.run(.render, qos: .userInteractive) { () -> RenderOutput in
                let extent = input.proxy.extent
                let brush = AppState.bakeBrush(masks: bake.masks, cache: bake.brushCache,
                                               extent: extent, context: side.ctx)
                let wand = AppState.bakeWand(masks: bake.masks, cache: bake.wandCache,
                                             extent: extent, source: input.proxy)
                let bitmaps = bake.base
                    .merging(brush.out) { _, baked in baked }
                    .merging(wand.out) { _, grown in grown }
                var rendered = Renderer.render(input.proxy, with: input.recipe, maskBitmaps: bitmaps)
                if let ov = side.overlay {
                    rendered = Renderer.renderMaskOverlay(rendered, maskBitmap: ov.bitmap, invert: ov.invert, feather: ov.feather, tightness: ov.tightness, opacity: 0.6)
                }
                let cg = side.ctx.createCGImage(rendered, from: rendered.extent)
                let concrete = cg.map { CIImage(cgImage: $0) } ?? rendered
                return RenderOutput(ci: concrete, cg: cg, histogram: HistogramReader.read(concrete),
                                    brushCache: brush.cache, wandCache: wand.cache)
            }
            // PUBLISH THE PIXELS, NOT THE RECIPE FOR THEM. `rendered` is a lazy CIImage — a filter
            // graph — and handing that to the UI means everything that later reads it re-runs the
            // whole chain, on whichever thread asks. Two things ask, and both ask on the main one:
            // the histogram redraws inside a SwiftUI Canvas closure, and the craft check measures
            // the frame 200 ms after the last edit. So each of them paid for a fresh render of the
            // proxy — noise reduction, masks, exposure fusion and all — every time the window drew.
            //
            // Measured on a 61 MB Sony ARW: an automated 600-step drag that should take 10 seconds
            // took 410, with the main thread unavailable 100% of the time in stalls of ~750 ms.
            // The GPU was never the problem; the main thread was rendering.
            //
            // `cg` has already been rasterised for the preview, so wrapping it costs nothing and
            // gives every downstream reader concrete 8-bit pixels. The craft measurements are 8-bit
            // regardless — `ImageStatistics` samples through `rgba8Sampled` — so nothing that was
            // being measured changes.
            let renderMs = Date().timeIntervalSince(renderStart) * 1000
            await MainActor.run {
                MainWork.record("render (detached)", ms: renderMs)
                // The caches the bake updated, back on the actor. Keyed by mask id, so an entry
                // for a mask that has since gone is dropped by the next bake's `live` filter.
                self.brushCache = out.brushCache
                self.wandCache = out.wandCache
                // Only for the photograph still open. `preview.active` is tagged with its URL and
                // the view ignores a stale one; these two are not, and a render that landed after
                // a photo switch used to put the old frame's histogram under the new frame's name
                // until its own first render arrived.
                if renderedURL == self.loadedURL {
                    self.preview.lastRenderedCI = out.ci
                    self.preview.histogram = out.histogram
                }
                if let cg = out.cg, let renderedURL {
                    self.preview.active = TaggedPreview(url: renderedURL,
                                                image: NSImage(cgImage: cg, size: .zero))
                }
                self.renderInFlight = false
                self.scheduleCraftCheck()
                // DELIBERATELY NOT CALLING `scheduleFineRender()`. See the note on it: rendering the
                // canvas at a higher resolution changes how the edit LOOKS, because two filters in
                // the detail pass are not resolution-scaled. Off until the eval harness says the
                // numbers hold — CLAUDE.md: whether an edit looks good is not a judgment call.
                if self.renderDirty { self.renderDirty = false; self.updateActiveRecipe() }
            }
        }
    }

    // MARK: - Seeing the photograph properly

    /// The long edge of the image the canvas is actually shown, once you stop touching things.
    ///
    /// 1200 px — the interactive proxy — is smaller than the canvas it is drawn into. On a 1432-point
    /// window the photograph gets roughly 945 points, which on a Retina display is about 1890 real
    /// pixels, so the proxy was being **upscaled by half again before anyone zoomed at all**. Hide the
    /// edit panel and the canvas gets bigger, which makes it worse. Reported as "hard to see photos
    /// true quality at times" and "not enough quality", and both were literally true.
    ///
    /// 2880 covers a full-screen canvas on a Retina display with headroom for a little zoom.
    /// `docs/ARCHITECTURE.md` has said "~2048px working" since the beginning while the code used
    /// 1200, so this direction is the documented intent rather than a departure from it.
    static let displayMaxEdge = 2880

    /// A higher-resolution copy of the photograph, **for looking at and never for measuring**.
    ///
    /// Built lazily, on the first fine render after a photo opens, so opening a photograph costs
    /// exactly what it did before. Roughly 22 MB materialised; held for the open frame only and
    /// dropped on switch.
    @ObservationIgnored private var displayCI: CIImage?
    @ObservationIgnored private var displayCIURL: URL?
    @ObservationIgnored private var fineToken = 0

    /// Re-render the frame at display resolution once the user stops interacting.
    ///
    /// **WRITTEN, MEASURED, AND CURRENTLY NOT CALLED.** Kept because the diagnosis is worth more than
    /// the code, and the fix it needs is specific.
    ///
    /// The idea is sound and standard: 1200 px while you drag a slider, real quality when you let go.
    /// The canvas genuinely is upscaling — 1200 px into roughly 1890 real pixels on a Retina window,
    /// and worse once the edit panel is hidden — so the softness people report is real, and this
    /// removes it.
    ///
    /// **It also changes how the edit looks, which is why it is off.** `Renderer`'s detail pass is
    /// *mostly* resolution-independent by design: `clarityRadius(for:)` scales clarity, texture and the
    /// sharpen radius to the shorter edge, and every mask works in fractions of `minEdge`. Two things
    /// do not scale:
    ///
    /// - `CINoiseReduction`'s `inputNoiseLevel`, which is an absolute figure
    /// - the `CIMedianFilter` chroma pass, which is a fixed 3×3 neighbourhood
    ///
    /// At 2880 px both smooth a smaller *fraction* of the frame than they do at 1200 px, so the picture
    /// comes back grittier. Reported immediately, on an overcast ISO 100 beach frame, as "the natural
    /// edit no longer looks natural" — which it did not.
    ///
    /// This is a **pre-existing disagreement between the preview and the export**, not one this
    /// function invented: the export renders at 9504 px and has always had proportionally weaker noise
    /// reduction than the 1200 px preview promised. This moved the preview along that same axis and in
    /// doing so made a long-standing discrepancy visible.
    ///
    /// **What it needs before switching on:** make those two filters scale with the image the way
    /// `clarityRadius` does, then prove it against the corpus with the eval harness
    /// (`docs/EVALUATION.md`) — preview, fine render and export must agree at three resolutions. That
    /// is a change to how every edit looks, so it is an eval-harness question and not a judgment call
    /// (CLAUDE.md, "What to do when stuck").
    private func scheduleFineRender() {
        fineToken += 1
        let token = fineToken
        // Long enough that a slider drag never triggers one mid-gesture; short enough to feel like
        // the picture simply sharpens when you let go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.fineRender(token: token)
        }
    }

    private func fineRender(token: Int) {
        guard fineToken == token, let url = loadedURL, let recipe = activeRecipe,
              let proxy = proxyCI, let fullRes = fullResCI else { return }
        // NOT WHILE A MASK OVERLAY IS UP, and not while painting. The red overlay is for placing a
        // mask, which is the one activity that wants the shape rather than the picture — and a
        // second render arriving underneath a brush stroke is a flicker in the middle of a gesture.
        guard !(showMaskOverlay && selectedMask != nil), paintingMaskId == nil,
              seedingMaskId == nil, !pickingInstance else { return }
        // Nothing to gain when the proxy already holds every pixel the file has: a small JPEG, or a
        // frame whose long edge is under the interactive size. Never upscale to look sharper.
        let native = max(fullRes.extent.width, fullRes.extent.height)
        guard native > max(proxy.extent.width, proxy.extent.height) + 1 else { return }

        let target = min(Self.displayMaxEdge, Int(native.rounded()))
        let cached = displayCIURL == url ? displayCI : nil
        // The masks scale from the interactive extent to the display extent — the SAME operation
        // that already takes them from 768 px to 1200 px (see `scaleMask`, and the mapValues at the
        // measure site). Deliberately NOT re-measured the way export does it: `LocalMasks.measure`
        // and `SubjectInstances.detect` are Vision passes costing hundreds of milliseconds, which is
        // affordable once per exported file and absurd every time somebody lets go of a slider.
        // Nothing real is lost — a mask has always been an upscale of something small.
        let sourceMasks = proxyMaskBitmaps
        let renderURL = url

        // Boxed for the same reason as the candidate stage's `Inputs`: `CIImage` is `Sendable` on
        // the macOS 27 SDK and not on the one CI builds against, so capturing `fullRes`, `cached`
        // and `sourceMasks` straight into the detached task compiles here and fails there. All
        // three are read-only for the life of the task.
        struct Inputs: @unchecked Sendable {
            let fullRes: CIImage
            let cached: CIImage?
            let masks: [String: CIImage]
        }
        let inputs = Inputs(fullRes: fullRes, cached: cached, masks: sourceMasks)

        Task.detached(priority: .utility) { [weak self] in
            // Build the display image if this is the first fine render for this photograph. For
            // anything that is not RAW, ImageIO decodes straight to the size we want; RAW goes
            // through the decode already in hand rather than reading the file twice.
            //
            // The RAW path is a real decode, so it queues on the decode lane like every other one;
            // the render that follows is on the render lane. Neither occupies this task's thread.
            let display: CIImage = await Offload.run(.decode, qos: .utility) { () -> ImageBox in
                if let cached = inputs.cached { return ImageBox(image: cached) }
                if let fast = PerceptionProxy.fromFile(url, maxEdge: target,
                                                       matching: inputs.fullRes.extent) {
                    return ImageBox(image: Self.materialiseDecoded(fast))
                }
                return ImageBox(image: Self.materialiseDecoded(
                    PerceptionProxy.downsample(inputs.fullRes, maxEdge: target)))
            }.image
            let displayBox = ImageBox(image: display)
            guard let cg = await Offload.run(.render, qos: .utility, { () -> CGImage? in
                let extent = displayBox.image.extent
                let bitmaps = inputs.masks.mapValues { Self.scaleMask($0, to: extent) }
                let rendered = Renderer.render(displayBox.image, with: recipe, maskBitmaps: bitmaps)
                return Self.sharedContext.createCGImage(rendered, from: rendered.extent)
            }) else {
                return
            }
            // Handed to a main-actor METHOD as one boxed value, rather than published from inside
            // `MainActor.run`.
            //
            // Two separate CI-only failures are being avoided here. `MainActor.run { guard let
            // self … }` reads naturally and does not compile there: `self` is task-isolated out
            // here, so capturing it in a main-actor closure is "sending 'self' risks causing data
            // races" — the compiler cannot see that every use inside is a main-actor one. Calling an
            // isolated method with `await` never sends `self` anywhere; it stays on its own actor.
            //
            // And the payload has to cross as a single `Sendable` box rather than as `CIImage` and
            // `CGImage` parameters, which would just move the same complaint from `self` to the
            // arguments. Sound for the same reason as `Inputs`: nothing here touches `finished`
            // again after the hop.
            await self?.adoptFineRender(FineRender(display: display, cg: cg,
                                                   url: renderURL, token: token))
        }
    }

    /// A finished fine render, boxed so it can cross from the render task to the main actor in one
    /// piece. `@unchecked` for the SDK reason recorded at the call site, and sound because the
    /// render task hands this over and never looks at it again.
    private struct FineRender: @unchecked Sendable {
        let display: CIImage
        let cg: CGImage
        let url: URL
        let token: Int
    }

    /// Publish a finished fine render, if it is still the one being waited for.
    ///
    /// Split out of `fineRender` so the hop back is a call to a main-actor method rather than a
    /// `MainActor.run` closure that captures `self` — see the note at the call site. The staleness
    /// checks live here, on the actor that owns the state they read, which is where they belong.
    @MainActor
    private func adoptFineRender(_ finished: FineRender) {
        guard fineToken == finished.token, loadedURL == finished.url else { return }
        displayCI = finished.display
        displayCIURL = finished.url
        // ONLY `active`, never `lastRenderedCI`. That one feeds the histogram and the craft
        // self-check, both of which are read off the 1200 px render — publishing a different
        // resolution into it would change measured numbers as a side effect of the picture
        // getting sharper, which is precisely the class of bug the note on `measureOn`
        // exists to warn about.
        preview.active = TaggedPreview(url: finished.url,
                                       image: NSImage(cgImage: finished.cg, size: .zero))
    }

    /// The objective craft self-check (clipping / skin / cast) runs ~200 ms after the last edit, so
    /// dragging a slider stays smooth and the flags settle once you stop.
    private func scheduleCraftCheck() {
        craftToken += 1
        let token = craftToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.craftToken == token, let r = self.preview.lastRenderedCI else { return }
            // OFF THE MAIN THREAD. Measured on a rendered proxy: `ImageStatistics.compute` 1.2 ms
            // and `FaceSkin.read` — which runs Vision — 10.2 ms, both of which used to run right
            // here, on the thread drawing the window, 200 ms after every edit. The debounce made it
            // rare rather than absent, and "rare" is what a stutter is.
            let measured = MeasuredFrame(image: r, condition: self.perception?.lighting.condition)
            Task.detached(priority: .userInitiated) {
                // On the vision lane — a render and a Vision request — not on this pool thread.
                let reading = await Offload.run(.vision) { () -> CraftFix.Reading? in
                    guard let stats = try? ImageStatistics.compute(measured.image) else { return nil }
                    return CraftFix.Reading(stats: stats,
                                            face: FaceSkin.read(in: measured.image),
                                            condition: measured.condition)
                }
                guard let reading else {
                    await MainActor.run {
                        guard self.craftToken == token else { return }
                        self.lastCraftReading = nil; self.activeCraftIssues = []
                    }
                    return
                }
                let issues = reading.issues
                await MainActor.run {
                    // The token is checked AGAIN on the way back: an edit made while this was
                    // measuring means these flags describe a frame that is no longer on screen.
                    guard self.craftToken == token else { return }
                    self.lastCraftReading = reading
                    self.activeCraftIssues = issues
                }
            }
            return
            #if false
            // Statistics and face are kept, not just the flag list: a subject fix is sized from the
            // same measurement the flags came from, so what the button does and what the warning
            // says can never be reading different numbers.
            guard let stats = try? ImageStatistics.compute(r) else {
                self.lastCraftReading = nil; self.activeCraftIssues = []; return
            }
            // The scene reading goes in with the measurement. Warm light measures exactly like a
            // white-balance error, and only the perception layer knows which one this is — without
            // it, every golden-hour frame is told it has a "strong colour cast" and offered a Fix
            // button that would take the golden hour out of it.
            let reading = CraftFix.Reading(stats: stats, face: FaceSkin.read(in: r),
                                           condition: self.perception?.lighting.condition)
            self.lastCraftReading = reading
            self.activeCraftIssues = reading.issues
            #endif
        }
    }

    func recordCurrentPick() {
        guard let selectedId = selectedCandidateId,
              let candidate = candidates.first(where: { $0.id == selectedId }) else { return }
        // Log the manual adjustments as the DIFF from the candidate Kelvin generated.
        let edits = manualTweaks()
        var pick = PreferencePick(
            imageId: imageId,
            perceptionHash: candidate.baseRecipe.provenance?.perceptionHash,
            shown: candidates.map { $0.id },
            chosen: selectedId,
            subsequentManualEdits: edits.isEmpty ? nil : edits)
        // WAITS FOR THE HASH, unlike the saved edit above. A pick is the training signal this whole
        // app is built around (CLAUDE.md, the one-sentence differentiator), and a pick recorded
        // against a blank image id is a pick that can never be joined back to a photograph. Better
        // to log it a second late than to log it useless.
        Task { [weak self] in
            guard let self else { return }
            pick.imageId = await self.resolvedImageId() ?? ""
            try? await self.store.record(pick: pick)
        }
    }

    /// The mask bitmaps for a full-resolution render — the merged subject/sky pair, plus a mask for
    /// every per-subject mask the recipe names.
    ///
    /// The per-subject part cannot simply re-detect and use what comes back. Instance ids are
    /// Vision's per-pass indices: run the segmentation again at 60 MP instead of 1200 px and
    /// `person0` may be a different person, or nobody. Trusting the id would export an edit landing
    /// on the wrong face, in a file that looked right on screen the whole time. So the pass the
    /// photographer actually edited against is handed forward as references, and the fresh
    /// detection is matched back onto it by geometry.
    ///
    /// A subject that cannot be matched is *reported*, not papered over: its bitmap is absent, the
    /// renderer skips that mask, and the status line says whose edit did not make it. Silently
    /// dropping a local edit from an export is the failure worth avoiding here.
    private func fullResolutionMaskBitmaps(for fullRes: CIImage) -> [String: CIImage] {
        var bitmaps = LocalMasks.measure(in: fullRes).bitmaps
        let wanted = Set(userMasks.compactMap(\.boundInstanceId))
        guard !wanted.isEmpty else { return bitmaps }

        let references = subjectInstances.filter { wanted.contains($0.id) }.map(\.reference)
        let matched = SubjectInstances.reidentify(SubjectInstances.detect(in: fullRes),
                                                  as: references)
        bitmaps.merge(matched.bitmaps) { _, fresh in fresh }
        if !matched.unmatched.isEmpty {
            let names = matched.unmatched
                .compactMap { id in userMasks.first { $0.instanceId == id }?.label }
                .joined(separator: ", ")
            statusMessage = "Couldn't find \(names) again at full size — that edit is not in the export"
        }
        return bitmaps
    }

    /// The name a photographer gave a subject mask, or the name Vision gave it — never a raw id.
    private func label(forInstanceId id: String) -> String {
        userMasks.first { $0.instanceId == id }?.name
            ?? userMasks.first { $0.instanceId == id }?.instanceLabel
            ?? subjectInstances.first { $0.id == id }?.label
            ?? "a subject mask"
    }

    func exportFullResolution(to exportURL: URL) async {
        // NOT a bare `return`. The workspace and the Export button appear as soon as the proxy
        // decodes, but `activeRecipe` is nil until the candidates land — so clicking Export in that
        // window, naming a file and pressing Save produced no file, no error and no message at all.
        // The user is left believing they exported something.
        guard let fullRes = fullResCI, let recipe = activeRecipe else {
            statusMessage = "Still preparing this photo — try the export again in a moment"
            return
        }
        // Refuse a destination that is one of the source photographs. Batch export refuses this
        // inside `Destination.prepare`; the single-photo path has only the save panel's generic
        // "Replace?" prompt, which is no defence against writing over the original being edited.
        let target = exportURL.standardizedFileURL.resolvingSymlinksInPath()
        let sources = folderPhotos + (imageURL.map { [$0] } ?? [])
        if sources.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == target }) {
            statusMessage = "That would overwrite an original — choose a different name or folder"
            return
        }
        isProcessing = true
        statusMessage = "Rendering full resolution…"
        // OFF THE MAIN ACTOR. `AppState` is `@MainActor`, and `async` does NOT move work off an
        // actor — an async method on a main-actor type runs on the main thread until it awaits
        // something that hops. So this ran a full-resolution render, an `ImageWriter.write`, and —
        // via `fullResolutionMaskBitmaps` — TWO 60-megapixel Vision passes, all on the thread
        // drawing the window. The app was frozen for the entire export, including the
        // "Rendering full resolution…" message, which could not paint.
        //
        // This is the third instance of a failure mode this codebase has documented twice
        // already: thumbnails decoding whole RAWs during view layout, and decode on the MainActor.
        // The pattern is always the same and always looks like correct code.
        //
        // Same navigation race as the share path: the render takes seconds, the filmstrip stays
        // live, and the pick log reads live state — so record only if this is still the same
        // photograph when the render lands.
        let renderedURL = imageURL
        let result = await renderCurrentPhoto(fullRes, recipe: recipe, to: exportURL,
                                              metadata: exportMetadata)

        switch result {
        case .success(let lost):
            if lost.isEmpty {
                statusMessage = "Exported \(exportURL.lastPathComponent)"
            } else {
                // Named, not counted. "One mask is missing" sends someone hunting; "Person 2" tells
                // them what to check.
                let names = lost.map { label(forInstanceId: $0) }.joined(separator: ", ")
                statusMessage = "Exported \(exportURL.lastPathComponent) — but \(names) "
                    + "couldn't be found again at full size, so that edit is not in the file"
            }
            // Exporting is the one unambiguous signal of preference, so it's logged. NOTE: nothing
            // currently reads this back — candidates are generated fresh per photo, by design (the
            // way to reuse an edit is Batch apply, not a cross-image average). The log exists so
            // that decision can be revisited with real data; it is not a live learning loop, and
            // the UI must not claim otherwise.
            if imageURL == renderedURL { recordCurrentPick() }
        case .failure(let error):
            statusMessage = "Export failed — \(error)"
        }
        isProcessing = false
    }

    /// The single-photo render-and-write path — ONE of it, shared by Export and Share, because a
    /// second copy is how the file someone texts stops matching the file they would have saved.
    /// Honours every export setting except the metadata policy, which each caller decides.
    ///
    /// The success value carries WHICH subject masks could not be found again at full resolution,
    /// because the renderer's response to a missing bitmap is to skip that mask silently. A
    /// per-subject local edit could therefore be absent from the written file while the status
    /// line said "Exported IMG_1234.jpg". The code that was supposed to report this existed
    /// (`fullResolutionMaskBitmaps`) and was never called from anywhere — dead since it was
    /// written, while the live path inlined the re-identification and discarded `unmatched`.
    private func renderCurrentPhoto(_ fullRes: CIImage, recipe: Recipe, to url: URL,
                                    metadata: ImageWriter.MetadataPolicy) async
        -> Result<[String], Error> {
        // The bitmaps are computed on the detached side, because that is where the Vision
        // passes are, and they are the expensive part. See `exportFullResolution` for why none
        // of this may run on the main actor.
        let masksNeeded = recipe.masks?.isEmpty == false
        let references = subjectInstances.filter { inst in
            userMasks.contains { $0.boundInstanceId == inst.id }
        }.map(\.reference)
        let input = ExportInput(fullRes: fullRes, recipe: recipe, url: url,
                                metadata: metadata, format: exportFormat,
                                size: exportSize, colorSpace: exportColorSpace)
        // Two lanes: the Vision passes on theirs, the write on the export lane. Neither is on a
        // cooperative thread while it works — see `Offload`.
        let measured = await Offload.run(.vision) { () -> ExportMasks in
            var bitmaps: [String: CIImage] = [:]
            var lost: [String] = []
            if masksNeeded {
                bitmaps = LocalMasks.measure(in: input.fullRes).bitmaps
                if !references.isEmpty {
                    let matched = SubjectInstances.reidentify(
                        SubjectInstances.detect(in: input.fullRes), as: references)
                    bitmaps.merge(matched.bitmaps) { _, fresh in fresh }
                    lost = matched.unmatched
                }
            }
            return ExportMasks(bitmaps: bitmaps, lost: lost)
        }
        do {
            try await Offload.run(.export) {
                try ImageWriter.write(
                    Renderer.render(input.fullRes, with: input.recipe, maskBitmaps: measured.bitmaps),
                    to: input.url, format: input.format, metadata: input.metadata,
                    size: input.size, colorSpace: input.colorSpace)
            }
            return .success(measured.lost)
        } catch { return .failure(error) }
    }

    /// The mask stack an export measured, and the subjects it could not find again. Boxed for the
    /// lane crossing, on the same promise as every other box in this file.
    private struct ExportMasks: @unchecked Sendable {
        let bitmaps: [String: CIImage]
        let lost: [String]
    }

    /// Render the current photograph for the share sheet and hand back the file, or nil with the
    /// reason already on the status line. The same render `exportFullResolution` does — recipe,
    /// masks, format, size — differing only in destination and in what metadata rides along.
    ///
    /// The file goes in a FRESH directory under the app's own temp, never beside anyone's
    /// originals (the promise in CLAUDE.md §3), and never over the previous share — Messages or
    /// AirDrop may still be copying that one when the next share starts. The system clears temp;
    /// nothing here needs to outlive it, because the render is reproducible from the edit.
    func renderCurrentPhotoForSharing() async -> URL? {
        // The button disables on `isPreparingShare`, but a keyboard-queued second press can land
        // before SwiftUI repaints — this guard is what actually prevents two concurrent renders.
        guard !isPreparingShare else { return nil }
        // Same trap as Export: the workspace appears before the candidates land, and a share
        // that silently produces nothing reads as a broken button.
        guard let fullRes = fullResCI, let recipe = activeRecipe else {
            statusMessage = "Still preparing this photo — try sharing again in a moment"
            return nil
        }
        isPreparingShare = true
        defer { isPreparingShare = false }
        statusMessage = "Rendering to share…"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(Branding.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        // The export filename, not a generic one: the file's name is what Messages shows and
        // what lands in someone's Downloads, and "kelvin-edit 3" tells them nothing.
        let out = dir.appendingPathComponent(suggestedExportName(ext: exportFormat.fileExtension))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            statusMessage = "Couldn't make a file to share — \(error)"
            return nil
        }
        // OPPOSITE default to Export. An export is a deliberate delivery with a panel in the
        // way; a share is three clicks into a message thread, so the position stays out unless
        // this photograph's toggle was set — AND this photograph verifiably has a position. The
        // second half matters: the flag can be true while the checkbox is hidden (set, then the
        // capture info was still loading), and a hidden control must never be the thing deciding
        // what leaves the machine. No location, no `asShot` by accident.
        let metadata: ImageWriter.MetadataPolicy =
            (shareIncludeLocation && capture.location != nil) ? .asShot : .withoutLocation
        // The photograph this render belongs to. The render takes seconds and nothing freezes
        // the filmstrip — nor should it — so by completion the user may be looking at another
        // frame entirely. The FILE is safe (everything above was captured before the await); the
        // pick log is not, and a "chosen" record for a photo the user never picked is exactly
        // the fake signal the preference store must not learn from.
        let renderedURL = imageURL
        switch await renderCurrentPhoto(fullRes, recipe: recipe, to: out, metadata: metadata) {
        case .success(let lost):
            if lost.isEmpty {
                statusMessage = "Sharing \(out.lastPathComponent)"
            } else {
                let names = lost.map { label(forInstanceId: $0) }.joined(separator: ", ")
                statusMessage = "Sharing \(out.lastPathComponent) — but \(names) "
                    + "couldn't be found again at full size, so that edit is not in the file"
            }
            // A share is an export by another door — but the pick is logged only when a service
            // is actually CHOSEN (see `SharePresenter.onDidChoose`), and only if this is still
            // the same photograph; the URL here is what the chooser callback checks against.
            pendingSharePickURL = renderedURL
            return out
        case .failure(let error):
            statusMessage = "Couldn't render for sharing — \(error)"
            return nil
        }
    }

    /// Render every photograph in this shoot that carries a saved edit, each with ITS OWN recipe.
    ///
    /// The hole this fills: `exportFullResolution` handles one photo, and Batch apply propagates ONE
    /// look across a folder by re-perceiving every frame. Neither renders the twenty frames somebody
    /// actually sat down and edited — which was the last step of a shoot, and had no button.
    ///
    /// Masks are re-measured per photograph, exactly as batch does: a subject mask is measured on
    /// the proxy and must be re-found at full resolution, and the frames differ.
    /// The running batch export, so it can be stopped. One at a time; the button that starts
    /// one is replaced by the one that stops it while it runs.
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    /// True for the life of a batch export. The footer swaps Export for Stop on it.
    private(set) var isExporting = false

    /// Start a batch export and remember it, so `cancelExport` has something to cancel.
    func startExport(to directory: URL) {
        // One at a time, genuinely: cancelling the old task and starting a new one left the old
        // one's `defer { isExporting = false }` to run seconds later, under the new export, and
        // the footer flipped back to "Export" while files were still being written.
        guard !isExporting else { return }
        exportTask = Task { await exportEdited(to: directory) }
    }

    /// Stop after the frame being written. A four-hundred-frame export is an hour, and until
    /// this there was no way out of one short of quitting — which, with files being written, is
    /// how half an image ends up under a real name. Files already written stay; the status line
    /// says how many.
    func cancelExport() {
        exportTask?.cancel()
    }

    func exportEdited(to directory: URL) async {
        isExporting = true
        defer { isExporting = false }
        // The batch's first perceive must not queue behind a background read-ahead generation —
        // the loop only yields BETWEEN frames, so without this the person watching the export
        // waits up to a whole generation before frame one starts. Same preemption `loadPhoto`
        // does; the cancelled frame goes back to the head of the queue for later.
        backgroundReadTask?.cancel()
        // `exportScope`, not `exportTargets`: a selection is the scope, the same rule Apply already
        // follows. The button's label is computed from the same call, so what it says and what this
        // writes cannot drift apart.
        let targets = exportScope()
        guard !targets.isEmpty else {
            statusMessage = exportKeepersOnly
                ? "Nothing to export is flagged Keep — press P on the ones you want, or untick Kept only"
                : "Nothing to export yet — edit a photo, or apply a look to the shoot"
            return
        }

        // Refuses to write into the folder the originals live in. `prepare` compares filesystem
        // identity rather than path strings, so a symlink or a /tmp-vs-/private/tmp spelling cannot
        // sneak past it — the same guard batch uses, for the same reason.
        let destination = BatchApply.Destination(directory: directory, onCollision: .uniqueSuffix,
                                                 format: exportFormat, metadata: exportMetadata)
        do { try destination.prepare(sources: targets) }
        catch {
            statusMessage = "Can't export there — \(error)"
            return
        }

        isProcessing = true
        var written = 0, failed = 0, unreadable = 0
        // Counted on the way OUT, not when the recipe is built: a frame that adapted fine and then
        // failed to write is a failure, and counting it here would make the two halves of the
        // summary add up to more than the number of files on disk.
        var adaptedWritten = 0
        var needsReopening: [String] = []
        let size = exportSize, space = exportColorSpace, scheme = exportNaming
        // Read once, before the loop: these name THIS export, and a text field edited mid-run must
        // not split a folder's files across two naming conventions.
        let label = exportLabel
        let prefix = exportPrefix, suffix = exportSuffix

        // PHASE ONE — decide what each frame gets, and where it goes. Sequential, on the actor.
        //
        // Name allocation CANNOT be parallelised. `uniqueURL` resolves a collision by asking the
        // filesystem what already exists, and nothing has been written yet at planning time — so two
        // frames with the same stem would both be told the name is free and the second would clobber
        // the first. Allocated names are therefore tracked in a set and fed back into the same
        // existence check, which is what that parameter is for.
        var jobs: [RenderJob] = []
        var allocated = Set<URL>()
        for (index, url) in targets.enumerated() {
            if Task.isCancelled { break }
            let saved = EditStore.load(for: url)
            // WHICH RECIPE THIS FRAME GETS, and the order is the whole contract:
            //
            // 1. The hand-made edit, rendered from the recipe stored with it. Exact, instant, and
            //    it outranks the shoot's look — see `ShootLook`.
            // 2. Otherwise the shoot's look, ADAPTED to this frame: decoded, perceived, measured
            //    and run through the engine so the style resolves against its own histogram.
            let recipe: Recipe?
            let lookName: String?
            var wasAdapted = false
            if let saved {
                // A sidecar written before recipes were stored cannot be reproduced without
                // re-running perception. Say which ones, rather than exporting something that is
                // not what they saw. NOT quietly downgraded to the shoot look: they edited this
                // frame by hand, and handing back a generated version of it is the wrong answer.
                guard let stored = saved.recipe else {
                    needsReopening.append(url.lastPathComponent); continue
                }
                recipe = stored
                lookName = saved.styleId
            } else if editedURLs.contains(url) {
                // Counted, not `continue`d silently: a sidecar that exists but won't decode used to
                // vanish from the arithmetic entirely, and "Exported 0" with no reason attached
                // reads as a broken button — which is exactly how its own developer read it.
                unreadable += 1; continue
            } else if let styleId = effectiveStyle(for: url),
                      let style = CandidateStyle.all.first(where: { $0.id == styleId }) {
                statusMessage = "Reading photo \(index + 1) of \(targets.count)…"
                let adapted: Recipe
                do {
                    adapted = try await adaptedRecipe(for: url, style: style)
                } catch {
                    failed += 1; continue
                }
                recipe = adapted
                wasAdapted = true
                // The recipe's OWN label, not the requested style's. They differ exactly when the
                // curator dropped the shoot's style for this frame and it fell back — and a file
                // named for a look it was not given is a lie that outlives the export.
                lookName = adapted.label ?? style.label
            } else {
                continue
            }
            guard let recipe else { failed += 1; continue }

            // THE FRAME'S OWN READ, for the "Describe the photo" scheme. This passed nil, so
            // the panel promised `_DSC0458_interior_overcast_person_soft.jpg` and the batch wrote
            // `_DSC0458_soft.jpg` — the preview and the files disagreed. The read is on disk by
            // now for every adapted frame (`adaptedRecipe` saves it) and for every frame that was
            // ever opened; a frame without one falls back to stem + look, which is the rule:
            // describe only what was actually judged.
            let named = PerceptionStore.load(for: url, modelId: perceptionProvider.activeModelID)
            let out = ExportNaming.uniqueURL(
                in: directory,
                stem: ExportNaming.stem(for: url, perception: named, look: lookName,
                                        scheme: scheme, label: label,
                                        prefix: prefix, suffix: suffix),
                ext: exportFormat.fileExtension,
                exists: { allocated.contains($0) || FileManager.default.fileExists(atPath: $0.path) })
            allocated.insert(out)
            jobs.append(RenderJob(recipe: recipe, source: url, out: out, wasAdapted: wasAdapted))
        }

        // Leftovers of a write cut off before its rename — a quit through `_exit` mid-frame, a
        // crash — are swept before anything new is written. Ours only, and old only; see the
        // function. A directory listing, so once per export, not per frame.
        await Offload.run(.io, qos: .utility) { ImageWriter.removeStalePartials(in: directory) }

        // PHASE TWO — decode, render and write. Concurrent, and this is where the time is.
        //
        // Measured on 60 MP RAWs with the perception cache warm: 10.3s a frame, of which the pixel
        // work is essentially all of it — 7.2s in the write alone (the render is lazy and is forced
        // there), 1.9s in full-resolution mask measurement, 0.9s in the proxy. Those stages are
        // independent per frame and were running strictly one after another, so a 400-frame export
        // took 68 minutes of a machine doing one thing at a time.
        //
        // ONE AT A TIME, AND THAT IS A MEASUREMENT, NOT AN OVERSIGHT.
        //
        // This ran three frames concurrently on the theory that the stages are independent per
        // frame. Measured on 8 real 60 MP RAWs with the cache warm: 81.6s sequential, 80.2s with
        // three lanes. A 1.7% difference — nothing — because the work is Core Image on a single
        // GPU, and lanes do not multiply a GPU. They queue on the same device and arrive at the
        // same time, having held three decoded 60 MP frames in memory to do it.
        //
        // So the lane count is 1 and the cost is paid honestly. The plan-then-execute split above
        // stays, because it fixed a real filename race that the old inline loop had: name
        // allocation now happens once, sequentially, against a set of what has already been
        // claimed. Raising this number is not a speed-up available to anyone; making the RENDER
        // cheaper is where the time is (`masks (full-res)` is 1.8s of a warm frame and `write`
        // forces the whole graph).
        let format = exportFormat, metadata = exportMetadata
        let lanes = 1
        var completed = 0
        // A shorter window than the scan's: frames here are ten seconds each, not tens of
        // milliseconds, so eight completions is already a minute and a half of evidence — and a
        // long window would keep quoting the cold first frames deep into a warm run.
        var eta = ProgressETA(window: 8)
        await withTaskGroup(of: (ok: Bool, adapted: Bool).self) { group in
            var next = 0
            func addJob() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask {
                    let ok = await Self.renderAndWrite(job, format: format, metadata: metadata,
                                                       size: size, colorSpace: space)
                    return (ok, job.wasAdapted)
                }
            }
            for _ in 0..<lanes { addJob() }
            // One in, one out: the group never holds more than `lanes` decoded frames at once.
            while let result = await group.next() {
                completed += 1
                eta.recordCompletion()
                if result.ok {
                    written += 1
                    if result.adapted { adaptedWritten += 1 }
                } else { failed += 1 }
                // Stopped: the frame that was being written has finished (its file is whole —
                // ImageWriter renames into place), and no further one starts.
                if Task.isCancelled { group.cancelAll(); break }
                statusMessage = "Exporting \(completed) of \(jobs.count)…"
                    + (eta.phrase(itemsLeft: jobs.count - completed).map { " \($0)" } ?? "")
                addJob()
            }
        }

        isProcessing = false
        if Task.isCancelled {
            statusMessage = "Export stopped — \(written) of \(jobs.count) written to \(directory.lastPathComponent)"
                + (written == 0 ? "" : " (those files are complete)")
            return
        }
        // When nothing was written, the REASON is the message — "Exported 0" with the explanation
        // trailing after a folder name is how a working feature gets reported as a broken one.
        if written == 0 {
            if !needsReopening.isEmpty {
                statusMessage = "Nothing exported — \(needsReopening.count) of these edits were saved "
                    + "before looks were stored inside them. Open each photo once (it re-saves in "
                    + "the current form), then export again"
            } else if unreadable > 0 {
                statusMessage = "Nothing exported — \(unreadable) saved edit\(unreadable == 1 ? "" : "s") "
                    + "could not be read back. Open those photos once to re-save them"
            } else {
                statusMessage = "Nothing exported — \(failed) failed to render or write"
            }
            return
        }
        var message = "Exported \(written) photo\(written == 1 ? "" : "s") to \(directory.lastPathComponent)"
        // The adapted count is stated separately because the two halves were made differently and
        // someone checking the folder should know which is which: one set is what they edited by
        // hand, the other is the shoot's look resolved per frame.
        if adaptedWritten > 0 {
            message += " · \(adaptedWritten) adapted from the shoot's look, "
                + "\(written - adaptedWritten) from your edits"
        }
        if failed > 0 { message += " · \(failed) failed" }
        if unreadable > 0 { message += " · \(unreadable) unreadable — open those photos once to re-save" }
        if !needsReopening.isEmpty {
            message += " · \(needsReopening.count) saved before this version — open each once to include it"
        }
        statusMessage = message
    }

    /// Resolve the shoot's style against ONE photograph: decode it, read it, measure it, and let the
    /// engine derive this frame's own corrective baseline underneath the style.
    ///
    /// This is the per-frame adaptation that the whole feature rests on, and it is why applying a
    /// look does not copy sliders. Frame 12 was shot into the sun and frame 13 was not; both are
    /// "Natural", and this is where Natural comes out different for each of them.
    ///
    /// **It resolves the style the way the canvas does, curator and all.** This used to build the
    /// requested `CandidateStyle` unconditionally while `loadPhoto` only selected it if it survived
    /// `CandidateCurator` — so on a frame the curator had dropped the style for, the preview showed
    /// one recipe and the export wrote another, with nothing on screen to say so. Both paths now go
    /// through `CandidateCurator.resolve`, and the returned recipe carries its own label so the
    /// filename names the look that was actually written.
    ///
    /// **AND IT MEASURES THE SAME IMAGE THE CANVAS DOES — the same size, built the same way.**
    /// `loadPhoto` used to measure on the 1200 px edit proxy while this measured on the 768 px
    /// perception proxy, so the two applied one curation rule to two sets of numbers. Measured over
    /// 15 real 60 MP frames with `kelvin-perceive compare-measure-edge`: 1 frame in 15 resolved to
    /// a different candidate, at ΔE 4.54 — `subjectLuma` differing by 0.007 moved that frame's
    /// Dramatic score from 0.572 to 0.523 across a `qualityFloor` of 0.55. Neither number was more
    /// correct than the other; there simply must be one of them.
    ///
    /// So the proxy is built by the same expression `loadPhoto` uses, not merely to the same size:
    /// `fromFile` decodes straight from the file and `downsample` scales the decoded frame, and for
    /// anything that is not RAW those are different pixels at identical dimensions — which would
    /// have left the same bug with a smaller blast radius, and been much harder to find twice.
    ///
    /// Expensive on purpose — a decode, a perception pass and two Vision passes per photograph — so
    /// it runs at export, once, and never while someone is browsing.
    private func adaptedRecipe(for url: URL, style: CandidateStyle) async throws -> Recipe {
        // PHOTO + STYLE → RECIPE IS DETERMINISTIC, so the answer is worth keeping. On a hit the
        // whole of this function is skipped, decode included — the caller decodes separately for
        // the render, so nothing below is needed to produce the file.
        //
        // Measured on 6 real 60 MP ARWs with `bench-export`: proxy 1.15s + statistics 0.01s +
        // proxy masks 0.21s + engine 0.00s + curate 0.50s, so 1.87s of a 20.03s frame. `curate` is
        // the expensive half, because resolving a style means rendering and scoring the whole
        // candidate set rather than the one asked for.
        //
        // Everything that changes the answer is in the KEY, not merely checked after loading —
        // including `RecipeEngine.tuningSignature`, so that sweeping `KELVIN_SKY_EV` cannot be
        // served the previous arm's recipes. See `ResolvedRecipeStore`.
        let modelIdForCache = perceptionProvider.activeModelID
        if let cached = ResolvedRecipeStore.load(for: url, styleId: style.id, modelId: modelIdForCache) {
            return cached
        }
        // Decode and proxy off the main actor. `AppState` is `@MainActor`, and doing this here
        // would block the thread drawing the window for every frame in the shoot.
        let decoded = try await Offload.run(.decode) { () -> DecodedForExport in
            let image = try ImageDecoder.decode(url: url)
            // Materialised, not lazy. A lazy proxy is a filter graph over the FULL frame, so every
            // measurement below would silently re-render all 60 megapixels again — the trap
            // `loadPhoto` documents and avoids.
            //
            // `fromFile` first, exactly as `loadPhoto` does it. For RAW it returns nil and both
            // paths fall through to the same downsample; for everything else it is the difference
            // between the pixels the canvas measured and a second, subtly different set.
            let proxy = PerceptionProxy.fromFile(url, matching: image.extent)
                ?? Self.materialiseDecoded(PerceptionProxy.downsample(image))
            return DecodedForExport(image: image, proxy: proxy)
        }
        // THE CACHE IS THE WHOLE PERFORMANCE STORY OF THIS FUNCTION. Measured over 25 frames at
        // 24 MP, perception was 6.43s of a 6.72s frame — 96% — and every other stage together was
        // under 0.3s. Served from cache, a frame costs roughly what the pixels cost, and a
        // 400-frame export goes from about 45 minutes to a couple.
        let modelId = perceptionProvider.activeModelID
        let perception: Perception
        if let cached = PerceptionStore.load(for: url, modelId: modelId) {
            perception = cached
        } else {
            // Perception is its own actor hop and stays here.
            perception = try await perceptionProvider.perceive(decoded.proxy)
            PerceptionStore.save(perception, for: url, modelId: modelId)
        }
        let work = DecodedForExport(image: decoded.image, proxy: decoded.proxy)
        let resolved = try await Offload.run(.vision) { () throws -> Recipe in
            let stats = try ImageStatistics.compute(work.proxy)
            // Per-photo subject + sky masks — each frame gets its own local decisions, measured on
            // its own proxy rather than inherited from whatever was open when the look was chosen.
            let m = LocalMasks.measure(in: work.proxy)
            let iso = ExifReader.iso(url: url)
            let recipes = RecipeEngine.candidates(perception: perception, statistics: stats,
                                                  subjectLuma: m.subjectLuma, skyLuma: m.skyLuma,
                                                  subjectOrigin: m.subjectOrigin,
                                                  iso: iso)
            // The whole set has to be built and scored, not just the one that was asked for.
            // Curation is not a per-candidate verdict: a style is dropped by the quality floor, OR
            // by being too close to one already chosen, OR by the four-slot cap — and the last two
            // are answerable only with the rest of the pool in hand. Rendering the requested style
            // alone and checking its score would agree with the canvas most of the time, which is
            // the worst kind of nearly-right.
            // ONE face detection for the whole set, on the UNGRADED proxy — byte for byte the
            // canvas's sequence (see `buildCandidates`). `score(rendered:)` detects inside each
            // candidate's own render instead, so a look dark enough to lose the face Vision found
            // on the plain proxy scored its skin against a different face set than its rivals did:
            // the two curators could then resolve different recipes for the same photograph, which
            // is the canvas showing one picture and the export writing another. It also ran Vision
            // once per candidate — 626 ms apiece on a three-face proxy — to answer the same question.
            let faces = FaceSkin.detect(in: work.proxy)
            var scored: [CandidateCurator.Scored] = []
            for recipe in recipes {
                let rendered = Renderer.render(work.proxy, with: recipe, maskBitmaps: m.bitmaps)
                guard let renderedStats = try? ImageStatistics.compute(rendered) else { continue }
                let score = AestheticEvaluator.score(stats: renderedStats,
                                                     face: FaceSkin.meter(in: rendered, faces: faces))
                scored.append(.init(recipe: recipe, score: score))
            }
            let resolution = CandidateCurator.resolve(from: scored, requested: style.id, count: 4)
            if let chosen = resolution.chosen { return chosen.recipe }
            // Nothing scored at all — a frame the evaluator could not read. Fall back to building
            // the requested style directly rather than failing the export: the photographer asked
            // for this look, and the curator having nothing to say is not a reason to skip a file.
            return RecipeEngine.candidate(perception: perception, statistics: stats, style: style,
                                          subjectLuma: m.subjectLuma, skyLuma: m.skyLuma,
                                          subjectOrigin: m.subjectOrigin, iso: iso)
        }
        ResolvedRecipeStore.save(resolved, for: url, styleId: style.id, modelId: modelIdForCache)
        return resolved
    }

    /// A decoded photograph and its proxy, boxed to cross the actor boundary. `CIImage` is safe to
    /// read from another thread here — the box exists to say so explicitly rather than to launder
    /// a race.
    private struct DecodedForExport: @unchecked Sendable {
        let image: CIImage
        let proxy: CIImage
    }

    /// One photograph's render-and-write, boxed for the same reason.
    private struct RenderJob: @unchecked Sendable {
        let recipe: Recipe
        let source: URL
        let out: URL
        /// Whether this frame's recipe came from the shoot's look rather than a hand edit, so the
        /// summary can say which half of the count was adapted. Carried on the job because the
        /// answer is decided at planning time and read after the work finishes on another thread.
        var wasAdapted = false
    }

    /// One frame: decode, measure, render, write.
    ///
    /// `nonisolated` and `async`, so it runs on the concurrent executor rather than hopping back to
    /// the main actor — which is the entire point of the task group above. Nothing here touches
    /// `AppState`; every value it needs is passed in.
    nonisolated private static func renderAndWrite(_ job: RenderJob,
                                           format: ImageWriter.Format,
                                           metadata: ImageWriter.MetadataPolicy,
                                           size: ImageWriter.Size,
                                           colorSpace: ImageWriter.ColorSpace) async -> Bool {
        // Three lanes in sequence — decode, Vision, write — each awaited. The task-group slot this
        // runs in bounds how many frames are in flight; the lanes are what keep the work off the
        // cooperative pool. See `Offload`.
        guard let decoded = try? await Offload.run(.decode, { () throws -> ImageBox in
            ImageBox(image: try ImageDecoder.decode(url: job.source))
        }) else { return false }
        let needsMasks = job.recipe.masks?.isEmpty == false
        let bitmaps = needsMasks
            ? await Offload.run(.vision) { MaskBox(bitmaps: LocalMasks.measure(in: decoded.image).bitmaps) }
            : MaskBox(bitmaps: [:])
        do {
            try await Offload.run(.export) {
                let rendered = Renderer.render(decoded.image, with: job.recipe, maskBitmaps: bitmaps.bitmaps)
                try ImageWriter.write(rendered, to: job.out, format: format, metadata: metadata,
                                      size: size, colorSpace: colorSpace)
            }
            return true
        } catch { return false }
    }

    /// Mask bitmaps crossing a lane boundary. Same promise as `ImageBox`.
    private struct MaskBox: @unchecked Sendable { let bitmaps: [String: CIImage] }

    /// Everything a detached export needs, boxed so it can cross the actor boundary. `CIImage` and
    /// `Recipe` are safe to read from another thread here — the box exists to say so explicitly
    /// rather than to launder a race.
    private struct ExportInput: @unchecked Sendable {
        let fullRes: CIImage
        let recipe: Recipe
        let url: URL
        let metadata: ImageWriter.MetadataPolicy
        let format: ImageWriter.Format
        let size: ImageWriter.Size
        let colorSpace: ImageWriter.ColorSpace
    }


    /// The manual edits as a DIFF from the candidate Kelvin generated — carried onto every batch
    /// photo (as offsets, so each frame keeps its own adapted baseline) and logged as the pick's
    /// subsequent edits. Only meaningfully-changed fields are included.
    private func manualTweaks() -> [String: Double] {
        var t: [String: Double] = [:]
        func d(_ key: String, _ a: Double, _ b: Double, _ eps: Double) { if abs(a - b) > eps { t[key] = a - b } }
        d("exposure_ev", edit.exposureEV, editBaseline.exposureEV, 0.01)
        d("contrast", edit.contrast, editBaseline.contrast, 0.5)
        d("highlights", edit.highlights, editBaseline.highlights, 0.5)
        d("shadows", edit.shadows, editBaseline.shadows, 0.5)
        d("whites", edit.whites, editBaseline.whites, 0.5)
        d("blacks", edit.blacks, editBaseline.blacks, 0.5)
        d("vibrance", edit.vibrance, editBaseline.vibrance, 0.5)
        d("saturation", edit.saturation, editBaseline.saturation, 0.5)
        d("clarity", edit.clarity, editBaseline.clarity, 0.5)
        d("texture", edit.texture, editBaseline.texture, 0.5)
        d("dehaze", edit.dehaze, editBaseline.dehaze, 0.5)
        d("fusion", edit.fusion, editBaseline.fusion, 0.5)
        d("tint", edit.tint, editBaseline.tint, 0.5)
        if let et = edit.temperatureK, let bt = editBaseline.temperatureK, abs(et - bt) > 5 {
            t["temperatureK"] = et - bt
        }
        return t
    }

    /// Pure: reads only its arguments, so a batch worker can call it off the actor.
    nonisolated static func applyTweaks(_ t: [String: Double], to g: inout GlobalAdjustments) {
        g.exposureEV = Self.clampStep(g.exposureEV + (t["exposure_ev"] ?? 0), -5...5, 0.05)
        g.contrast = Self.clampStep(g.contrast + (t["contrast"] ?? 0), -100...100, 1)
        g.highlights = Self.clampStep(g.highlights + (t["highlights"] ?? 0), -100...100, 1)
        g.shadows = Self.clampStep(g.shadows + (t["shadows"] ?? 0), -100...100, 1)
        g.whites = Self.clampStep(g.whites + (t["whites"] ?? 0), -100...100, 1)
        g.blacks = Self.clampStep(g.blacks + (t["blacks"] ?? 0), -100...100, 1)
        g.vibrance = Self.clampStep(g.vibrance + (t["vibrance"] ?? 0), -100...100, 1)
        g.saturation = Self.clampStep(g.saturation + (t["saturation"] ?? 0), -100...100, 1)
        g.clarity = Self.clampStep(g.clarity + (t["clarity"] ?? 0), -100...100, 1)
        g.texture = Self.clampStep(g.texture + (t["texture"] ?? 0), -100...100, 1)
        g.dehaze = Self.clampStep(g.dehaze + (t["dehaze"] ?? 0), 0...100, 1)
        g.fusion = Self.clampStep(g.fusion + (t["fusion"] ?? 0), 0...100, 1)
        g.tint = Self.clampStep(g.tint + (t["tint"] ?? 0), -100...100, 1)
        // As-shot is 6500 — the renderer's no-op — not 5500. Against 5500 a tweak of +200 K landed
        // 800 K warmer than the frame it was measured on.
        if let dt = t["temperatureK"] { g.temperatureK = (g.temperatureK ?? 6500) + dt }
    }

    /// The ids of the auto-masks on the current candidate (e.g. "subject", "sky"), for the UI.
    var baseMaskIds: [String] { baseMasks.map { $0.id } }

    /// Whether a SUBJECT was segmented in this photo — not necessarily a person.
    ///
    /// The name is kept because it is what every call site reads, but the doc used to say "a person"
    /// and that was the mislabel behind a reported halo: `SubjectMask.subject` falls back to Vision's
    /// generic salient-instance segmentation, which on a landscape returns the landscape. Subject and
    /// Background masks are legitimate on any subject — a dog, a bird, a sea stack — so this stays
    /// the gate for those. Anything that genuinely needs a *person* asks `subjectIsPerson`.
    var hasPerson: Bool { proxyMaskBitmaps["subject"] != nil }

    /// Whether the subject mask came from person segmentation rather than the salient-object
    /// fallback. The difference is invisible in the mask and decisive in the copy: a card that says
    /// "the detected person" over a mask of a rock is how somebody ends up lifting a rock.
    var subjectIsPerson: Bool { subjectOrigin == .person }
    var hasSky: Bool { proxyMaskBitmaps["sky"] != nil }

    /// A binding for the white-balance slider (absolute Kelvin; nil → as-shot, which is 6500).
    ///
    /// 6500 and not 5500, because 6500 is what the renderer's no-op is and lower Kelvin renders
    /// WARMER: reporting as-shot as 5500 drew the thumb 1000 K to the warm side of the picture
    /// actually on screen, showed the control as modified when nothing had been applied, and made
    /// the smallest possible drag jump the photograph a thousand Kelvin. The same sentinel had
    /// already been found and fixed once in the engine (see `RecipeEngine`'s note); this was the
    /// copy in the slider.
    var temperatureBinding: Binding<Double> {
        Binding(get: { self.edit.temperatureK ?? 6500 },
                set: { self.edit.temperatureK = $0; self.updateActiveRecipe() })
    }

    // Active look's white balance for the rail (nil = as-shot).
    /// Straight from `edit` rather than from `activeRecipe`, which no longer publishes. Identical
    /// by construction: `updateActiveRecipe` assigns `finalRecipe.global = edit`.
    var activeTemperature: Double? { edit.temperatureK }

    /// Pure, so the batch worker can clamp off the actor too.
    nonisolated static func clampStep(_ v: Double, _ r: ClosedRange<Double>, _ step: Double) -> Double {
        let c = min(r.upperBound, max(r.lowerBound, v))
        return (c / step).rounded() * step
    }

    /// Results of the off-main candidate build. CIContext/CGImage are thread-safe; NSImage built
    /// from a CGImage is immutable here, so carrying them across is sound.
    private struct CandidateBatch: @unchecked Sendable {
        let scored: [CandidateCurator.Scored]
        let previews: [String: NSImage]
    }

    /// Everything the decode stage produces. Bundled so the whole of it can be computed on a
    /// background thread and handed back in one hop — decoding a 60 MP RAW, materialising the
    /// proxy and hashing the file are all far too slow to sit on the main thread.
    private struct DecodedPhoto: @unchecked Sendable {
        let fullRes: CIImage
        let perceptionProxy: CIImage
        let proxy: CIImage
        let originalPreview: NSImage?
    }

    /// What measuring the proxy yields: histogram statistics, the local mask stack, and the focus
    /// reading. Vision segmentation and the statistics pass are both heavy enough to freeze the UI.
    private struct MeasuredPhoto: @unchecked Sendable {
        let stats: ImageStatistics
        let masks: LocalMasks.Measured
        let focus: FocusMeasure.Reading
        /// Each separable subject in the frame, for the mask list.
        let instances: [SubjectInstances.Instance]
    }

    /// The photograph most recently asked for, readable from any lane without the main actor.
    ///
    /// STALE WORK IS DROPPED AT THE LANE DOOR. Arrowing through a shoot asks for a decode per key
    /// press, and the one that matters is the last. Every stage after the decode already checks
    /// `imageURL == url` and bails, but a job that has reached the head of a serial lane has
    /// already been paid for — measured at a second per RAW decode, so a burst of ten presses put
    /// the frame you stopped on nine seconds behind frames you had left. A lane job looks here
    /// first and declines if the request has moved on.
    nonisolated private static let latestRequest = LatestRequest()

    /// The app's own account of a photograph's life: opened, decoded, perceived, candidates — with
    /// times. `log show --predicate 'subsystem == "app.usekelvin.kelvin"'` used to return four
    /// hours of Apple's noise and nothing from Kelvin, which made "it did something odd" a question
    /// with no evidence. Four lines per photograph is the whole cost.
    nonisolated private static let lifecycle = Logger(subsystem: Branding.bundleIdentifier, category: "Lifecycle")
    private final class LatestRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        func set(_ u: URL) { lock.withLock { url = u } }
        func isCurrent(_ u: URL) -> Bool { lock.withLock { url == u } }
    }

    /// The measurement's two inputs, boxed to cross onto the Offload lanes. Same promise as
    /// `Inputs` in the candidate build: read-only for the whole of the measurement.
    private struct MeasureInputs: @unchecked Sendable {
        let proxy: CIImage
        let measureOn: CIImage
    }

    /// Everything the vision lane measures — `MeasuredPhoto` minus the focus reading, which is
    /// Core Image and runs on its own lane alongside.
    private struct MeasuredSansFocus: @unchecked Sendable {
        let stats: ImageStatistics
        let masks: LocalMasks.Measured
        let instances: [SubjectInstances.Instance]
    }

    /// The decode lane's OWN Core Image context. A `CIContext` serialises its renders behind one
    /// lock, and the read-ahead decode holding that lock while parked inside RawCamera — with the
    /// foreground's renders queued behind it — is exactly the shape of the 21 August 2026 deadlock.
    /// Decodes materialise through this context; everything that renders an already-decoded image
    /// uses `sharedContext`; the two never wait on each other. Same `(unsafe)` reasoning as below.
    nonisolated(unsafe) static let decodeContext: CIContext = {
        let opts: [CIContextOption: Any] = [.cacheIntermediates: false, .highQualityDownsample: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: opts) }
        return CIContext(options: opts)
    }()

    /// `materialiseShared`, through the decode context. For use inside `Offload.run(.decode)` only.
    nonisolated static func materialiseDecoded(_ image: CIImage) -> CIImage {
        guard let cg = decodeContext.createCGImage(image, from: image.extent) else { return image }
        return CIImage(cgImage: cg)
    }

    /// Shared with the background candidate build — a CIContext is thread-safe and expensive to
    /// create, so one instance serves both.
    ///
    /// KEEP the `(unsafe)`. Xcode 27 reports it as unnecessary because the macOS 27 SDK marks
    /// CIContext Sendable; the SDK CI builds against does not, and there plain `nonisolated`
    /// cannot be applied to a non-Sendable constant at all. Same trap as
    /// KelvinCore/Render/ImageWriter — this site is where it was taken.
    nonisolated(unsafe) static let sharedContext: CIContext = {
        let opts: [CIContextOption: Any] = [.cacheIntermediates: true, .highQualityDownsample: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: opts) }
        return CIContext(options: opts)
    }()

    /// Render a lazy CIImage into a concrete bitmap-backed one, so downstream passes sample real
    /// pixels instead of re-evaluating the whole graph each time.
    private func materialise(_ image: CIImage) -> CIImage { Self.materialiseShared(image) }

    private func ciToNSImage(_ ciImage: CIImage) -> NSImage? { Self.ciToNSImageShared(ciImage) }

    // Static twins of the two above, for use inside `Task.detached` during load. `CIContext` is
    // documented as thread-safe and `sharedContext` is already used this way by the candidate
    // build, so both stages can share the one GPU context rather than each making its own.
    nonisolated static func materialiseShared(_ image: CIImage) -> CIImage {
        guard let cg = sharedContext.createCGImage(image, from: image.extent) else { return image }
        return CIImage(cgImage: cg)
    }

    nonisolated static func ciToNSImageShared(_ ciImage: CIImage) -> NSImage? {
        guard let cg = sharedContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSZeroSize)
    }
}

/// What a finished render produces, and the only thing a render wakes.
@Observable
@MainActor
final class PreviewState {
    /// The rendered proxy, tagged with the photograph it belongs to so a frame that lands after a
    /// photo switch is ignored rather than shown under the new one's name.
    var active: AppState.TaggedPreview?
    /// The same pixels as a CIImage, for the histogram and the craft self-check. Materialised from
    /// the CGImage rather than left as a filter graph — see the render site.
    var lastRenderedCI: CIImage?
    /// The histogram of `lastRenderedCI`, computed on the render lane with it. See `RenderOutput`.
    var histogram: HistogramView.Reading?
}

/// The photograph on the canvas. Its own view so that a new render redraws the image without
/// re-evaluating the panel beside it.
struct PreviewImage: View {
    @Bindable var preview: PreviewState
    let url: URL?
    let showingOriginal: Bool
    let originalImage: NSImage?
    let zoom: Double
    let pan: CGSize
    /// The photograph in words, for VoiceOver. Passed in rather than reached for: this view has no
    /// `AppState`, and it should not grow one to say a sentence.
    var spoken: String = "The photograph being edited"

    var body: some View {
        let live = preview.active.flatMap { $0.url == url ? $0.image : nil }
        if let img = showingOriginal ? originalImage : (live ?? originalImage) {
            // DRAWN INTO A CANVAS, NOT LAID OUT AS AN IMAGE. `Image(nsImage:).resizable().scaledToFit()`
            // is the obvious spelling, and it is what this was — but a new `NSImage` arrives on every
            // tick of a slider drag, and every new image view value invalidated its layout, which
            // invalidated every flexible stack above it, which re-measured the whole window: 37% of
            // main-thread time in a profile of the drag was `sizeThatFits` and nothing else. A
            // `Canvas` takes whatever size it is offered and has no intrinsic size to re-ask about,
            // so swapping the pixels inside it costs a draw and no layout. The fit is the same
            // arithmetic `scaledToFit` does, with the 24 pt padding applied as an inset. (A CALayer
            // with the CGImage as `contents` was tried next and measured no better — the remaining
            // cost is Core Animation's own commit, which every spelling pays.)
            Canvas { ctx, size in
                let natural = img.size
                guard natural.width > 0, natural.height > 0 else { return }
                let available = CGSize(width: max(0, size.width - 48), height: max(0, size.height - 48))
                let scale = min(available.width / natural.width, available.height / natural.height)
                let w = natural.width * scale, h = natural.height * scale
                ctx.draw(Image(nsImage: img),
                         in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The photograph itself. Announced as what the model read rather than as "image",
                // and marked `.updatesFrequently` so VoiceOver does not re-read the whole label on
                // every tick of a slider drag.
                .accessibilityLabel(spoken)
                .accessibilityAddTraits(.updatesFrequently)
                .scaleEffect(zoom, anchor: .center)
                .offset(pan)
                // Identity is the PHOTOGRAPH, not the rendered image. The image is replaced on
                // every slider move, so keying the transition on it would crossfade the live edit
                // and destroy the one thing this preview exists for.
                .id(url)
                .transition(.opacity)
        }
    }
}

/// The histogram, likewise: it reads the rendered pixels, so it belongs to the render rather than
/// to the panel it is drawn at the top of.
struct HistogramHost: View {
    @Bindable var preview: PreviewState
    var body: some View { HistogramView(reading: preview.histogram) }
}

// MARK: - Signature: the temperature rail

struct TemperatureRail: View {
    /// Marks along the scale, coloured by their Kelvin. nil temperatures (as-shot) are omitted.
    let marks: [(k: Double, emphasized: Bool)]
    var showTicks = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(KelvinScale.gradient)
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .opacity(0.55)
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    let x = CGFloat(KelvinScale.position(mark.k)) * geo.size.width
                    Circle()
                        .fill(KelvinScale.color(mark.k))
                        .frame(width: mark.emphasized ? 11 : 6, height: mark.emphasized ? 11 : 6)
                        .overlay(Circle().stroke(Theme.base, lineWidth: mark.emphasized ? 2.5 : 1.5))
                        .shadow(color: mark.emphasized ? KelvinScale.color(mark.k).opacity(0.6) : .clear, radius: 5)
                        .position(x: min(max(x, 6), geo.size.width - 6), y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 14)
    }
}

// MARK: - Root

/// Presents the system share sheet anchored to the Share button, and holds the picker while its
/// menu is up — `NSSharingServicePicker` is not retained by the menu it shows, so a local would
/// deallocate under the open menu. The previous picker is released when the next share replaces
/// it, which is as precise as it needs to be for one small object.
@MainActor
final class SharePresenter: NSObject, NSSharingServicePickerDelegate {
    /// The AppKit view under the SwiftUI button, planted by `ShareAnchor`.
    weak var anchor: NSView?
    private var picker: NSSharingServicePicker?
    /// Runs when the user actually PICKS a service — not when the menu opens, and not when it is
    /// dismissed. The pick log rides on this: a share menu cancelled with Escape is not "this is
    /// the one I wanted", and recording at file-ready time was logging preference signals for
    /// shares that never happened.
    var onDidChoose: (() -> Void)?

    func present(_ items: [Any]) {
        guard let anchor, anchor.window != nil else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    // Delegate calls arrive on the main thread; the protocol requirement is nonisolated, so this
    // is the save-panel shape again: `assumeIsolated`, true by construction.
    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker,
                                          didChoose service: NSSharingService?) {
        guard service != nil else { return }   // nil is the menu being dismissed
        MainActor.assumeIsolated { onDidChoose?() }
    }
}

/// A zero-size AppKit view laid under the Share button, existing only because the share picker
/// anchors to a real `NSView` and SwiftUI offers no other route to one.
private struct ShareAnchor: NSViewRepresentable {
    let presenter: SharePresenter
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        presenter.anchor = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        presenter.anchor = nsView
    }
}

struct ContentView: View {
    /// Owned by `KelvinApp` rather than created here, so the File menu can drive the same state
    /// the window shows — a menu command with no route to the app's state is a dead menu.
    @Bindable var appState: AppState
    @State private var isTargeted = false
    @State private var panStart = CGSize.zero
    /// How tall the preview column is, so the filmstrip can be told what it may take.
    @State private var paneHeight: Double = 600
    @State private var zoomStart = 1.0
    /// A class in `@State` on purpose: the picker and the anchor view must keep their identity
    /// across body re-evaluations, and nothing observes them — nothing on screen changes when
    /// they do.
    @State private var sharePresenter = SharePresenter()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // `KELVIN_PRINT_CHANGES=1` prints which dependency re-evaluated this body, per evaluation.
        // Diagnostics only: this is the root of the window, and a body evaluation here is the
        // expensive kind. See Diagnostics.swift for the rest of the instruments.
        let _ = Diagnostics.noteRootBodyEvaluation()
        let _ = Diagnostics.printChangesEnabled ? Self._printChanges() : ()
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            // As soon as the photo is decoded. Waiting for perception before showing ANYTHING
            // meant dropping a file and watching an empty drop zone for the length of a model
            // run — the photo is right there, so show it and let the looks arrive around it.
            if appState.proxyCI != nil {
                workspace
            } else {
                emptyState
            }
        }
        .background(Theme.base)
        .preferredColorScheme(.dark)
        // The drop target is the WHOLE WINDOW, not just the empty state. It used to live only on
        // the empty state, which meant that once you had a photo open there was no way at all to
        // bring another one in — dragging did nothing, and there was no Open command either. The
        // filmstrip only ever shows the folder you came from, so a second shoot was unreachable.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { @MainActor in await appState.openDropped(providers) }
            return true
        }
        // A drop hint over the workspace too — without it, dragging onto an open photo gives no
        // sign the window will take it.
        .overlay {
            if isTargeted && appState.proxyCI != nil {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.glow.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .background(Theme.base.opacity(0.35))
                    .overlay(
                        Text("Drop to open")
                            .font(Theme.ui(15, .semibold))
                            .foregroundColor(Theme.ink)
                    )
                    .padding(18)
                    .allowsHitTesting(false)
            }
        }
        // Culling is keyboard work. Clicking a flag costs a second or two per frame, which across
        // a few hundred frames is most of an hour of pure motion — so the decision and the move to
        // the next photo are one keystroke. Hidden buttons rather than a visible toolbar: they
        // exist to carry the shortcut, not to be clicked.
        .overlay {
            if appState.proxyCI != nil {
                VStack(spacing: 0) {
                // ⌘ combinations are safe while typing — nothing types ⌘R — so they stay installed.
                Group {
                    Button("") { appState.setZoom(appState.zoom * 1.25) }
                        .keyboardShortcut("=", modifiers: .command)
                    Button("") { appState.setZoom(appState.zoom / 1.25) }
                        .keyboardShortcut("-", modifiers: .command)
                    Button("") { appState.resetToCandidate() }
                        .keyboardShortcut("r", modifiers: .command)
                    Button("") { appState.invertSelectedMask() }
                        .keyboardShortcut("i", modifiers: .command)
                }
                // EVERYTHING BELOW IS A LETTER SOMEBODY MIGHT BE TYPING — including the shifted
                // ones, since `⇧C` is how you type a capital C, and the arrow keys, which move a
                // caret before they move to the next photograph.
                if !appState.isEditingText {
                Group {
                    Button("") { appState.flagCurrentAndAdvance(.keep) }
                        .keyboardShortcut("p", modifiers: [])
                    Button("") { appState.flagCurrentAndAdvance(.reject) }
                        .keyboardShortcut("x", modifiers: [])
                    Button("") { appState.showMaskOverlay.toggle(); appState.onEdit() }
                        .keyboardShortcut("o", modifiers: [])
                    // `H` is what Lightroom binds healing to, and SHORTCUTS-PROPOSED listed it as
                    // unadopted only because healing had no tool mode to toggle. It has one now.
                    Button("") { appState.healToolActive.toggle() }
                        .keyboardShortcut("h", modifiers: [])
                    // One pair of keys sizes whichever round tool has the canvas. The heal tool
                    // works at a tenth the brush's scale, so it gets its own step — sharing the
                    // brush's 0.02 would jump a heal from smallest to largest in three presses.
                    Button("") {
                        if appState.healToolActive { appState.adjustHealRadius(by: -0.002) }
                        else { appState.adjustBrushRadius(by: -0.02) }
                    }
                        .keyboardShortcut("[", modifiers: [])
                    Button("") {
                        if appState.healToolActive { appState.adjustHealRadius(by: 0.002) }
                        else { appState.adjustBrushRadius(by: 0.02) }
                    }
                        .keyboardShortcut("]", modifiers: [])
                    Button("") { appState.selectCandidateIndex(0) }
                        .keyboardShortcut("1", modifiers: [])
                    Button("") { appState.selectCandidateIndex(1) }
                        .keyboardShortcut("2", modifiers: [])
                    Button("") { appState.selectCandidateIndex(2) }
                        .keyboardShortcut("3", modifiers: [])
                    Button("") { appState.selectCandidateIndex(3) }
                        .keyboardShortcut("4", modifiers: [])
                    Button("") { Task { await appState.advance(by: 1) } }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { Task { await appState.advance(by: -1) } }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                // A SECOND GROUP because SwiftUI's ViewBuilder takes ten children and no more, and
                // a group that silently drops its eleventh shortcut would be a bug nobody could see.
                Group {
                    // Lightroom's vocabulary where Kelvin has the same action, so hands that already
                    // know one editor do not have to learn this one. Only bound where the action
                    // genuinely exists — see docs/SHORTCUTS-PROPOSED.md for what was left out and
                    // why, including the keys that collide.
                    //
                    // `Z` joins `P` rather than replacing it: `P` is in the shipped shortcuts sheet
                    // and in people's fingers, and taking it away to match a list would be a cost
                    // paid by the only user this app currently has.
                    Button("") { appState.flagCurrentAndAdvance(.keep) }
                        .keyboardShortcut("z", modifiers: [])
                    Button("") { appState.clearFlagOnCurrent() }
                        .keyboardShortcut("u", modifiers: [])
                    // Before/after as a TOGGLE, alongside press-and-hold. Holding is right when you
                    // want a glance; a toggle is right when you want to look properly.
                    Button("") { appState.showingOriginal.toggle() }
                        .keyboardShortcut("\\", modifiers: [])
                    Button("") { appState.toggleFilmstrip() }
                        .keyboardShortcut("/", modifiers: [])
                    // Comparing Kelvin's answers against each other, which is the one act the app
                    // exists for and had no key. `C` is free and is what the word starts with;
                    // `⇧C` is taken and means something else.
                    Button("") { appState.toggleCompare() }
                        .keyboardShortcut("c", modifiers: [])
                    // A view entered with one keystroke has to be leavable with the key everything
                    // else is leavable with.
                    Button("") { appState.closeCompare() }
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("") { appState.toggleZoomRatio() }
                        .keyboardShortcut(.space, modifiers: [])
                    Button("") { openExportPanel() }
                        .keyboardShortcut("e", modifiers: .shift)
                    // Selecting frames in the strip. ⌘A / ⇧⌘A are the system's own pair for this
                    // and mean nothing else here, so borrowing them costs no other shortcut.
                    Button("") { appState.selectAllPhotos() }
                        .keyboardShortcut("a", modifiers: .command)
                    Button("") { appState.clearSelection() }
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                }
                Group {
                    // The mask kit. `M` opens the section rather than drawing anything, because
                    // "masking tool" in the list is a mode and Kelvin's masks are objects you add.
                    Button("") { appState.addUserMask(.brush) }
                        .keyboardShortcut("b", modifiers: [])
                    Button("") { appState.addUserMask(.linear) }
                        .keyboardShortcut("l", modifiers: [])
                    Button("") { appState.addUserMask(.radial) }
                        .keyboardShortcut("r", modifiers: [])
                    Button("") { appState.addUserMask(.colorRange) }
                        .keyboardShortcut("c", modifiers: .shift)
                    Button("") { appState.addUserMask(.luminance) }
                        .keyboardShortcut("i", modifiers: .shift)
                    Button("") { appState.adjustSelectedFeather(by: 4) }
                        .keyboardShortcut("]", modifiers: .shift)
                    Button("") { appState.adjustSelectedFeather(by: -4) }
                        .keyboardShortcut("[", modifiers: .shift)
                }
                }
                }
                .opacity(0).frame(width: 0, height: 0)
            }
        }
        .task { await appState.loadDemoIfRequested() }
        .sheet(isPresented: $showShortcutsSheet) { ShortcutsSheet() }
        // The only confirmation in the app, for the only action that touches an original. It names
        // the Trash rather than saying "delete", because where the files go is the reason this is
        // an acceptable thing to offer at all.
        .confirmationDialog(
            appState.trashPrompt,
            isPresented: Binding(get: { !appState.pendingTrash.isEmpty },
                                 set: { if !$0 { appState.pendingTrash = [] } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { appState.confirmTrash() }
            Button("Cancel", role: .cancel) { appState.pendingTrash = [] }
        } message: {
            Text("They go to the Finder's Trash, so you can put them back. Your edits are kept "
                 + "either way — restore a photo and its edit is still there.")
        }
    }

    @State private var showShortcutsSheet = false

    // MARK: Header — wordmark + instrument status readout

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(KelvinScale.gradient)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                Text(Branding.displayName.uppercased())
                    .font(Theme.ui(15, .semibold))
                    .tracking(4)
                    .foregroundColor(Theme.ink)
                // Which build you are looking at, in the window as well as on the Dock icon — the
                // Dock is no help when the window is full-screen or the icon is hidden behind
                // another. Absent entirely in a release; see BuildIdentity.
                if let badge = BuildIdentity.badge {
                    Text(badge)
                        .font(Theme.mono(9, .semibold))
                        .tracking(1)
                        .foregroundColor(Theme.base)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.warn))
                        .help("A build from source, not the installed app")
                }
            }
            Spacer()
            HStack(spacing: 12) {
                if appState.isProcessing {
                    ProgressView().controlSize(.small).tint(Theme.glow)
                } else {
                    Circle().fill(Theme.glow).frame(width: 5, height: 5)
                }
                Text(appState.statusMessage)
                    .font(Theme.mono(11))
                    .foregroundColor(Theme.inkDim)
                Button(action: { showShortcutsSheet = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard").font(.system(size: 10))
                        Text("Shortcuts").font(Theme.mono(10))
                    }
                    .foregroundColor(Theme.inkDim)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                // ⌘/ rather than the "?" the tooltip used to promise: nothing was bound to "?",
                // and it needs Shift on most layouts anyway, so it would not have fired reliably
                // even if it had been. ⌘/ is the macOS convention for this and takes no modifier
                // gymnastics.
                .keyboardShortcut("/", modifiers: .command)
                .help("Keyboard shortcuts (⌘/)")

                // ⌥⌘P, and NOT the bare Tab that Lightroom and Capture One use.
                //
                // Tab was the first choice for exactly the right reason — it is a photographer's
                // muscle memory and the proposed-shortcuts list does not claim it — and it does not
                // work. AppKit takes Tab for keyboard focus traversal before a SwiftUI
                // `keyboardShortcut` ever sees it: tested against a real window, the key moved focus
                // and the panel stayed put. Claiming it in the tooltip while nothing happened would
                // be worse than picking a duller key that fires.
                Button(action: { togglePanel() }) {
                    Image(systemName: panelCollapsed ? "sidebar.right" : "sidebar.trailing")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.inkDim)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: [.command, .option])
                .help(panelCollapsed ? "Show the edit panel (⌥⌘P)" : "Hide the edit panel (⌥⌘P)")

                // ⌘, has always worked and the menu item has always been there, but there was no
                // way to DISCOVER either from inside the window — and this app hides its title bar,
                // so the menu is the last place someone looks. Two preferences that change what
                // happens to your files live in there; they should not be a thing you have to
                // already know about.
                // Next to Settings, because the two things someone wants after using an app for ten
                // minutes are to change something and to ask for something. A pre-alpha with no
                // route for the second is one that only hears from people annoyed enough to go
                // looking for the repository.
                Button(action: { NSWorkspace.shared.open(AppInfo.featureRequestURL) }) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.inkDim)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Request a feature")

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.inkDim)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        // The title bar is hidden, so this strip IS the window's top edge — the first thing the eye
        // lands on and the right place for the material to announce itself.
        .glassSurface(edge: .bottom)

    }

    // MARK: Empty state — the scale is the hero

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Text("Read the light.")
                        .font(Theme.ui(40, .medium))
                        .foregroundColor(Theme.ink)
                    Text("Drop a photo — or a whole folder. \(Branding.displayName) reads the scene on-device and offers a few finished looks: pick one, tune it, then apply it across the shoot. Open a single frame and the rest of its folder is listed alongside it, ready when you want it.")
                        .textSelection(.enabled)
                        .font(Theme.ui(14))
                        .foregroundColor(Theme.inkDim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }

                // The blackbody scale, labelled — the signature, front and centre.
                VStack(spacing: 8) {
                    TemperatureRail(marks: [(2900, false), (5500, false), (8600, false)], showTicks: true)
                        .frame(width: 440)
                    HStack {
                        Text("2900K warm").foregroundColor(KelvinScale.color(2900))
                        Spacer()
                        Text("5500K daylight").foregroundColor(Theme.inkDim)
                        Spacer()
                        Text("8600K cool").foregroundColor(KelvinScale.color(8600))
                    }
                    .font(Theme.mono(10))
                    .frame(width: 440)
                }

                Button(action: appState.chooseAndOpen) {
                    // "or folder", because the panel accepts both and always has. Saying only
                    // "photo" made opening a folder look like something the app was not offering,
                    // and made the shoot appearing in the strip look like a surprise.
                    Text("Choose a photo or folder")
                        .font(Theme.ui(13, .semibold))
                        .foregroundColor(Theme.base)
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(Capsule().fill(Theme.glow))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("RAW · JPEG · HEIC · PNG · TIFF   —   on-device, your photos never leave your Mac")
                .font(Theme.mono(10))
                .foregroundColor(Theme.inkFaint)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(isTargeted ? Theme.glow.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .center) {
            if isTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.glow.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .padding(24)
            }
        }
    }

    // MARK: Workspace

    /// Canvas, footer and filmstrip — everything that is not the edit panel.
    ///
    /// Extracted so `workspace` can hand it to an `HSplitView` when the panel is showing and use it
    /// on its own when it is not. **That structure is the fix, not a tidy-up.** The first attempt put
    /// an `if` around the sidebar *inside* the split view, which builds and does nothing:
    /// `HSplitView` is backed by `NSSplitView`, it resolves its panes when it is created, and a pane
    /// that disappears from the `ViewBuilder` afterwards leaves the divider and the space behind.
    /// Reported, correctly, as "panel doesn't collapse".
    private var canvasColumn: some View {
        // Preview + the active look's white balance on the rail
        VStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack {
                        if appState.comparing {
                            // The grid TAKES the canvas rather than floating over it. Kelvin's
                            // answers deserve the same space the photograph gets, and a panel
                            // hovering over a dimmed picture would be comparing two crops of
                            // whatever it did not cover.
                            CandidateCompareView(appState: appState)
                        } else {
                        PreviewImage(preview: appState.preview,
                                     url: appState.imageURL,
                                     showingOriginal: appState.showingOriginal,
                                     originalImage: appState.originalPreviewImage,
                                     zoom: appState.zoom,
                                     pan: appState.pan,
                                     spoken: appState.imageURL.map {
                                         appState.spokenDescription(for: $0)
                                     } ?? "The photograph being edited")
                        if appState.activePreviewImage == nil,
                           appState.originalPreviewImage == nil,
                           appState.isProcessing {
                            // A LOADING STATE, not a blank canvas and not the previous photograph.
                            //
                            // The previews are tagged with the photo they belong to, so once the
                            // open moves on there is nothing to draw until the new frame decodes —
                            // and an empty rectangle for a second or two reads as the app having
                            // dropped something. Showing the OLD photo instead would be worse: it
                            // is the wrong picture under the new one's name, which is how somebody
                            // ends up editing a frame they are not looking at.
                            //
                            // So: say what is happening. The status line carries the detail
                            // ("Loading the perception model", "Reading the scene"); this is just
                            // the acknowledgement that the click landed.
                            VStack(spacing: 14) {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(Theme.glow)
                                Text(appState.statusMessage)
                                    .font(Theme.mono(11))
                                    .foregroundColor(Theme.inkDim)
                                    .transition(.opacity)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        }
                    }
                    // Photos come in from the filmstrip, a drop, or the arrow keys. A hard cut
                    // between two frames of the same shoot reads as a flicker; a short fade makes
                    // it obvious that the frame changed rather than the edit.
                    .animation(Motion.gated(Motion.standard, reduceMotion), value: appState.imageURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        if appState.showingOriginal { beforeBadge }
                        else if appState.paintingMaskId != nil { paintingBadge }
                        else if appState.pickingInstance { pickingBadge }
                        else if appState.seedingMaskId != nil { seedingBadge }
                        else if appState.healToolActive { healingBadge }
                    }
                    .contentShape(Rectangle())
                    // One drag does the right thing: paint (brush armed), else pan (zoomed in).
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            // Picking takes the drag but does nothing with it: a click is a drag of
                            // zero distance, and letting the pan branch run would slide the photo
                            // under the pointer between press and release.
                            if appState.pickingInstance || appState.seedingMaskId != nil { return }
                            // Same reason as picking: the heal lands on release, so the drag branch
                            // must not pan the photo out from under the pointer first.
                            if appState.healToolActive { return }
                            if appState.paintingMaskId != nil { appState.paintAt(v.location, container: geo.size) }
                            else if appState.zoom > 1.01 {
                                appState.pan = CGSize(width: panStart.width + v.translation.width,
                                                      height: panStart.height + v.translation.height)
                            }
                        }
                        .onEnded { v in
                            // Resolved on RELEASE rather than as an `onTapGesture`, which would
                            // otherwise wait to see whether a second click is coming (the canvas
                            // has a double-click-to-fit) and make selecting feel laggy.
                            if appState.pickingInstance {
                                appState.pickInstance(at: v.location, container: geo.size)
                                return
                            }
                            if appState.seedingMaskId != nil {
                                appState.seedWand(at: v.location, container: geo.size)
                                return
                            }
                            if appState.healToolActive {
                                // ⌥ removes instead of adding, so a misjudged patch is undone
                                // where you are already looking rather than from the panel.
                                appState.healAt(v.location, container: geo.size,
                                                remove: NSEvent.modifierFlags.contains(.option))
                                return
                            }
                            panStart = appState.pan
                        })
                    // Pinch to zoom (trackpad).
                    .simultaneousGesture(MagnificationGesture()
                        .onChanged { appState.setZoom(zoomStart * $0) }
                        .onEnded { _ in zoomStart = appState.zoom })
                    // Draggable handles for the selected radial / graduated mask.
                    .overlay { maskCanvasOverlay(in: geo.size) }
                    .overlay { subjectHighlightOverlay(in: geo.size) }
                    // This was written but never attached, so the old "circle the spots" toggle
                    // drew nothing at all — the one control that was supposed to prove the repair
                    // had happened. Found by looking at the window instead of the tests.
                    .overlay { repairSpotOverlay(in: geo.size) }
                    // Double-click to fit.
                    .onTapGesture(count: 2) { appState.resetZoom(); zoomStart = 1 }
                    // Escape leaves an armed mode. Best-effort by nature — it needs the canvas to
                    // hold focus — which is why the badge is tappable too.
                    .onExitCommand {
                        if appState.pickingInstance { appState.pickingInstance = false }
                        else if appState.seedingMaskId != nil { appState.seedingMaskId = nil }
                        else if appState.paintingMaskId != nil { appState.paintingMaskId = nil }
                        else if appState.healToolActive { appState.healToolActive = false }
                    }
                }
                previewFooter
                if appState.folderPhotos.count > 1 {
                    FilmstripView(photos: appState.visiblePhotos,
                                  current: appState.imageURL,
                                  // Two thirds of the pane. The strip may take most of the window
                                  // when someone is culling rather than editing, but never so much
                                  // that the photograph it is a strip OF has nowhere left to go.
                                  maxHeight: paneHeight * 0.66,
                                  editedURLs: appState.editedURLs,
                                  thumbnail: appState.thumbnail(for:),
                                  onSelect: { url, extend, toggle in
                                      appState.stripClick(url, extend: extend, toggle: toggle)
                                  },
                                  selected: appState.selectedPhotos,
                                  onTrash: { appState.requestTrash($0) },
                                  onDismiss: { appState.dismiss($0) },
                                  flags: appState.flags,
                                  totalCount: appState.folderPhotos.count,
                                  keeperCount: appState.keeperCount,
                                  rejectCount: appState.rejectCount,
                                  onFlag: { url, flag in appState.setFlag(flag, for: url) },
                                  filter: $appState.stripFilter,
                                  softURLs: Set(appState.focus.filter { $0.value.isSoft }.keys),
                                  softCount: appState.softCount,
                                  scanProgress: appState.focusScanProgress,
                                  scanETA: appState.focusScanETA,
                                  onScanFocus: appState.scanFocus,
                                  sharpest: appState.sharpestInRun,
                                  bestNeedsScan: appState.bestFilterNeedsScan,
                                  bestNote: appState.bestFilterNote ?? "",
                                  exposureConcerns: appState.exposureConcerns(for:),
                                  scanNote: appState.scanNote(for:),
                                  spokenDescription: appState.spokenDescription(for:),
                                  sortKey: $appState.photoSort,
                                  sortReversed: $appState.photoSortReversed,
                                  grouping: $appState.stripGrouping,
                                  groups: appState.stripGroups,
                                  canGroupByPlace: appState.canGroupByPlace,
                                  sortPending: appState.sortOrderPending,
                                  onExpand: appState.filmstripDidExpand)
                    // THE STRIP GETS ITS HEIGHT FIRST, and the photograph takes what is left.
                    // Without this the preview — which asks for every point it can get — wins the
                    // negotiation, and a strip dragged open to six rows is simply clipped by the
                    // bottom of the window: the rows exist, they are drawn, and you cannot see
                    // them. Layout priority inverts that, so dragging the strip taller shrinks the
                    // photograph, which is what dragging it is *for*.
                    .layoutPriority(1)
                }
            }
            .frame(minWidth: 460)
            .background(Theme.base)
            // The column's own height, handed to the filmstrip so it knows how far it may grow.
            // Read from a background rather than by wrapping the column: a `GeometryReader` in the
            // layout would take the column over, and an earlier attempt to keep it out of the way
            // by pinning it to zero height duly reported zero — which clamped the strip to a single
            // row. A background is offered exactly the size of what it sits behind.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { paneHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in paneHeight = h }
                }
            )

    }

    /// THE PANEL COMES OFF, and the photograph takes the room.
    ///
    /// Reported as "edit panel needs to be able to be collapsed so you have more room to see edited
    /// photo — too small now". 360 points of a 1432-point window is a quarter of it, permanently,
    /// whether or not anything in there is being used. Judging a photograph and adjusting one are
    /// different activities, and only the second needs the sliders.
    ///
    /// The whole `HSplitView` is swapped out rather than one of its panes — see `canvasColumn` for
    /// why a conditional pane silently does nothing.
    private var workspace: some View {
        Group {
            if panelCollapsed {
                canvasColumn
            } else {
                // NOT `HSplitView`, because it would not do as it was told.
                //
                // Asked for twice — "like the smaller panel size to be the default", then "still
                // larger than I like" — and `idealWidth: 280` did not produce 280. `HSplitView`
                // treats an ideal width as a hint and divides the leftover between its panes, so at
                // the 940 pt minimum window the panel took about 470 pt whatever it was asked for.
                // A plain `.frame(width:)` gets the number honoured but takes the drag away, which
                // was the complaint before that ("you have to click a button not drag").
                //
                // An `HStack` with its own handle gets both, plus the thing neither `HSplitView`
                // arrangement could do: **the width is remembered**. Dragging the panel is a
                // statement about how someone works, and making them repeat it every morning is the
                // mistake `FilmstripFold` exists to avoid.
                HStack(spacing: 0) {
                    canvasColumn
                    panelDivider
                    sidebar
                        // The live value wins while dragging; the stored one the rest of the time.
                        .frame(width: liveWidth ?? panelWidth)
                        // NO `.clipped()` HERE, and that is the lesson rather than an omission.
                        //
                        // The panel was narrowed to 280 without the panel's *contents* being made to
                        // work at 280 — the slider rows, the mask grid, the repair toggles all still
                        // wanted their old width. Clipping turned that overflow into a clean cut
                        // straight through every control: "Fusion +55" halved, "Backgr…", a sliced
                        // "4 SPOTS", sliders running off the edge. It looked like a rendering fault,
                        // and it was rightly rejected on sight.
                        //
                        // Clipping hides a layout problem instead of solving one. The width now
                        // starts where the contents actually fit; making it genuinely narrow is a
                        // pass over those controls, not a smaller number here.
                        // Glass, and a rim lit along the temperature curve. The panel is the largest
                        // piece of chrome and it sits beside the photograph rather than under it, so
                        // it is the right place for the material to read.
                        //
                        // A blackbody wash sits UNDER the material: warm at the top where the panel
                        // meets the header, cooling as it falls. Two percent at its strongest — far
                        // too little to name a colour, just enough that the glass has something to
                        // refract and the panel stops reading as a flat grey slab. Without it a
                        // material over a dark app on a dark desktop has nothing to blur and looks
                        // identical to the opaque fill it replaced.
                        .background {
                            LinearGradient(colors: [Theme.warm.opacity(0.05),
                                                    Theme.cool.opacity(0.035)],
                                           startPoint: .top, endPoint: .bottom)
                                .background(Theme.glassSurface)
                        }
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.rimLight).frame(width: 1)
                        }
                }
            }
        }
        // The way back in, when there is no panel to put a button on. Sits over the top-right of the
        // canvas — the corner the panel used to occupy, so the eye is already there.
        .overlay(alignment: .topTrailing) {
            if panelCollapsed {
                Button(action: { togglePanel() }) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.inkDim)
                        .padding(8)
                        .background(Circle().fill(Theme.surface.opacity(0.9)))
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(14)
                .help("Show the edit panel (⌥⌘P)")
            }
        }
    }

    /// Whether the edit panel is hidden. Remembered between launches: someone who works with it shut
    /// is telling you how they work, and making them say it again every morning is the same mistake
    /// the filmstrip's fold made before `FilmstripFold` existed.
    @AppStorage("panel.collapsed") private var panelCollapsed = false

    /// How wide the edit panel is, in points, remembered between launches.
    ///
    /// **300 by default**, down from the 360 it was pinned at when the width could not be changed at
    /// all.
    ///
    /// 300 specifically, and not a round guess: while the panel was briefly an `HSplitView` pane
    /// with `minWidth: 300`, that lower bound is the size it got dragged to and kept — "before you
    /// started editing the panel that was the smallest size that i liked, and you could drag to that
    /// size as the minimum". So the size that was reached by dragging is now the size it opens at,
    /// and the range still goes narrower for anyone who wants it.
    ///
    /// Clamped on the way in as well as on the way out, so a value edited by hand in defaults — or
    /// left behind by a future change to the bounds — cannot produce a panel that swallows the
    /// window or one too narrow to read.
    /// 360 is where the panel's contents currently fit. Narrower is a content problem, not a number.
    @AppStorage("panel.width") private var panelWidth: Double = 360

    /// The lower bound is 340 because that is the narrowest the *existing* controls survive. It was
    /// briefly 260, which produced a panel whose every row was sliced off at the edge. Lower it when
    /// the controls inside can take it, and not before.
    private static let panelWidthRange: ClosedRange<Double> = 340...560

    /// The width while a drag is in flight, kept out of `UserDefaults` so the gesture stays smooth.
    /// Nil when nothing is being dragged, at which point `panelWidth` is the truth.
    @State private var liveWidth: Double?

    /// The width the current drag began at. Nil when no drag is in flight.
    @State private var panelWidthStart: Double?

    /// The drag handle between the photograph and the panel.
    ///
    /// Two points of hairline with a wider invisible grab area, because a divider that is as easy to
    /// grab as it is to see would have to be thick enough to be furniture. `onHover` swaps the
    /// cursor so it advertises itself the way a Mac divider does.
    private var panelDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        // IN GLOBAL COORDINATES, and this is the whole fix for the jumping.
                        //
                        // A `DragGesture` reports `translation` relative to the view it is attached
                        // to — and this view is the divider, which MOVES as the drag resizes the
                        // panel. So each frame measured the pointer against a handle that had just
                        // shifted underneath it, the translation partly cancelled itself, and the
                        // panel stuttered and jumped instead of tracking the pointer. Reported as
                        // "doesn't move left to right without jumping".
                        //
                        // `.global` is a frame that does not move while the layout does, so the
                        // translation means what it says.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                // Anchored to the width the drag STARTED at. `translation` is
                                // cumulative from the start of the gesture, so applying it to the
                                // live width on every change compounds it and the panel flies to a
                                // bound after a few pixels of movement.
                                let start = panelWidthStart ?? panelWidth
                                if panelWidthStart == nil { panelWidthStart = start }
                                // Dragging left widens the panel, hence the subtraction: the handle
                                // sits on the panel's leading edge.
                                let proposed = start - value.translation.width
                                // INTO `@State` DURING THE DRAG, NOT `@AppStorage`.
                                //
                                // Reported as "little glitchey when draging", and this was why: an
                                // `@AppStorage` write is a `UserDefaults` write, and this fires on
                                // every frame of the gesture. Sixty synchronous defaults writes a
                                // second, each one notifying every observer of that key, is a stutter
                                // you can feel in the drag. The live value is local; the preference
                                // is written once, on release, which is also the only moment it
                                // means anything.
                                liveWidth = min(max(proposed, Self.panelWidthRange.lowerBound),
                                                Self.panelWidthRange.upperBound)
                            }
                            .onEnded { _ in
                                if let settled = liveWidth { panelWidth = settled }
                                liveWidth = nil
                                panelWidthStart = nil
                            }
                    )
            )
    }

    private func togglePanel() {
        withAnimation(Motion.gated(Motion.standard, reduceMotion)) {
            panelCollapsed.toggle()
        }
    }

    private var beforeBadge: some View {
        Text("BEFORE")
            .font(Theme.mono(11, .semibold)).tracking(2).foregroundColor(Theme.base)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.ink.opacity(0.75))).padding(30)
    }

    private var paintingBadge: some View {
        Text("PAINTING · drag to brush")
            .font(Theme.mono(11, .semibold)).tracking(1).foregroundColor(Theme.base)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.glow.opacity(0.9))).padding(30)
    }

    /// Says what to do AND how to get out. An armed mode with no visible exit is a trap, and this
    /// one takes over the click the canvas otherwise uses for panning.
    ///
    /// The badge is the exit, and that is deliberate rather than decorative: `onExitCommand` below
    /// only fires when the canvas actually holds focus, which is not guaranteed once a slider or a
    /// text field in the panel has been touched. Escape is offered because it is what a Mac user
    /// will try first; the tappable badge is what makes the promise keepable either way.
    private var pickingBadge: some View {
        Text("SELECT · click a subject · esc or tap here to cancel")
            .font(Theme.mono(11, .semibold)).tracking(1).foregroundColor(Theme.base)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.glow.opacity(0.9))).padding(30)
            .contentShape(Capsule())
            .onTapGesture { appState.pickingInstance = false }
            .help("Cancel selecting")
    }

    private var seedingBadge: some View {
        Text("WAND · click the thing you want · esc or tap here to cancel")
            .font(Theme.mono(11, .semibold)).tracking(1).foregroundColor(Theme.base)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.glow.opacity(0.9))).padding(30)
            .contentShape(Capsule())
            .onTapGesture { appState.seedingMaskId = nil }
            .help("Cancel picking a point")
    }

    /// Same contract as the other armed modes: says what to do and how to get out, and the badge
    /// itself is the exit for when the canvas has lost focus and Escape will not fire.
    private var healingBadge: some View {
        Text("HEAL · click a blemish · esc or tap here to finish")
            .font(Theme.mono(11, .semibold)).tracking(1).foregroundColor(Theme.base)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.glow.opacity(0.9))).padding(30)
            .contentShape(Capsule())
            .onTapGesture { appState.healToolActive = false }
            .help("Finish healing")
    }

    /// Which subject the pointer is over in the mask list, outlined on the photo. "Person 2" names
    /// nobody until you can see which one it is, and picking the wrong row means an edit landing on
    /// the wrong face.
    @ViewBuilder
    private func subjectHighlightOverlay(in container: CGSize) -> some View {
        if !appState.showingOriginal, let id = appState.highlightedInstanceId,
           let instance = appState.subjectInstances.first(where: { $0.id == id }) {
            let rect = appState.imageRect(in: container)
            SubjectHighlight(instance: instance, imageFrame: rect,
                             normToView: { appState.normToView($0, $1, in: rect) })
        }
    }

    /// Every healed spot, ringed, while the heal tool has the canvas.
    ///
    /// Only while the tool is active: a patch that worked should be invisible the rest of the time,
    /// and rings over a photograph are clutter for every second you are not asking where they are.
    /// The tool being a mode is what makes that unambiguous — the old version keyed this on hover
    /// over the controls, so the rings vanished the moment you looked at the picture.
    @ViewBuilder
    private func repairSpotOverlay(in container: CGSize) -> some View {
        if appState.healToolActive, !appState.showingOriginal, !appState.healSpots.isEmpty {
            let rect = appState.imageRect(in: container)
            ZStack(alignment: .topLeading) {
                ForEach(Array(appState.healSpots.enumerated()), id: \.offset) { _, spot in
                    // A RING, not a disc: the point is to see what is inside it and judge the
                    // patch. Filling it would hide the only evidence.
                    let centre = appState.normToView(spot.x, spot.y, in: rect)
                    let radius = max(9, spot.radius * min(rect.width, rect.height) * 2.2)
                    Circle()
                        .stroke(Theme.glow.opacity(0.9), lineWidth: 1.5)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(centre)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// On-canvas handles for the selected radial / graduated mask — drag directly on the image to
    /// place, size, and rotate the mask instead of nudging sliders.
    @ViewBuilder
    private func maskCanvasOverlay(in container: CGSize) -> some View {
        if !appState.showingOriginal, let mid = appState.selectedUserMaskId,
           let m = appState.userMasks.first(where: { $0.id == mid }) {
            let rect = appState.imageRect(in: container)
            let center = appState.normToView(m.cx, m.cy, in: rect)
            switch m.kind {
            case .radial:
                // Divided by the same framed/source scale `resizeRadial` MULTIPLIES by. `radius`
                // is a fraction of the SOURCE short edge (masks live in source space, before
                // geometry), while `rect` is the FRAMED image on screen — so on a straightened
                // photo, where the auto-crop shrinks the frame, drawing without the divide made
                // the dashed circle jump smaller the instant you dragged the size handle, and stop
                // marking where the effect actually lands.
                let rPx = m.radius * min(rect.width, rect.height) / appState.framedToSourceScale
                Circle().stroke(Theme.glow.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: rPx * 2, height: rPx * 2).position(center).allowsHitTesting(false)
                handle(at: center) { appState.moveMask(mid, to: appState.viewToNorm($0, in: rect).0,
                                                        appState.viewToNorm($0, in: rect).1) }
                handle(at: CGPoint(x: center.x + rPx, y: center.y), small: true) {
                    appState.resizeRadial(mid, edgeAt: $0, in: rect)
                }
            case .linear:
                let rad = m.angle * .pi / 180
                let dir = CGPoint(x: sin(rad), y: -cos(rad))            // gradient direction (0° = up)
                let perp = CGPoint(x: dir.y, y: -dir.x)
                let len = max(rect.width, rect.height)
                Path { p in
                    p.move(to: CGPoint(x: center.x - perp.x * len, y: center.y - perp.y * len))
                    p.addLine(to: CGPoint(x: center.x + perp.x * len, y: center.y + perp.y * len))
                }.stroke(Theme.glow.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .allowsHitTesting(false)
                handle(at: center) { appState.moveMask(mid, to: appState.viewToNorm($0, in: rect).0,
                                                        appState.viewToNorm($0, in: rect).1) }
                handle(at: CGPoint(x: center.x + dir.x * 54, y: center.y + dir.y * 54), small: true) {
                    appState.rotateLinear(mid, handleAt: $0, in: rect)
                }
            case .instance, .skin:
                // No handles — the shape is the subject's, not something to drag. But show WHICH
                // subject: the sliders below say "Exposure", and on a frame with three people
                // there is otherwise nothing on screen saying whose. A skin mask scoped to one
                // person gets the same box for the same reason; scoped to everyone it has no
                // instanceId, the lookup below finds nothing, and no box is drawn.
                //
                // GATED ON THE OVERLAY TOGGLE, and that is the fix for a real complaint: this box
                // used to be drawn for as long as the mask was selected, with nothing anywhere
                // that would put it away. The Overlay button (O) hid the red and left the box
                // sitting on the photograph, so the only control that removed it was the mask's
                // trash can — which takes the edits with it. The box is a label saying where the
                // mask falls, exactly like the red is, so it belongs to the same switch. The
                // radial and linear guides above are deliberately NOT gated: those are handles you
                // drag, and hiding a control is a different thing from hiding an annotation.
                if appState.showMaskOverlay,
                   let instance = appState.subjectInstances.first(where: { $0.id == m.instanceId }) {
                    SubjectHighlight(instance: instance, imageFrame: rect,
                                     normToView: { appState.normToView($0, $1, in: rect) })
                }
            case .wand:
                // A crosshair on the seed. There is nothing to drag — the region is grown, not
                // shaped — but WHERE YOU CLICKED is the one input a wand has, and a tolerance that
                // suddenly takes half the frame reads as a broken slider until you can see that the
                // seed landed on the sand rather than the rock. Gated on the overlay toggle because
                // it is an annotation and not a handle, the same rule the instance highlight follows.
                if appState.showMaskOverlay {
                    Path { p in
                        p.move(to: CGPoint(x: center.x - 7, y: center.y))
                        p.addLine(to: CGPoint(x: center.x + 7, y: center.y))
                        p.move(to: CGPoint(x: center.x, y: center.y - 7))
                        p.addLine(to: CGPoint(x: center.x, y: center.y + 7))
                    }
                    .stroke(Color.white, lineWidth: 1)
                    .shadow(color: .black.opacity(0.8), radius: 1)
                }
            case .brush, .colorRange, .luminance, .background, .subject, .sky:
                EmptyView()
            }
        }
    }

    private func handle(at p: CGPoint, small: Bool = false, onDrag: @escaping (CGPoint) -> Void) -> some View {
        let d: CGFloat = small ? 13 : 17
        return Circle().fill(Theme.glow)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: d, height: d).position(p)
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { onDrag($0.location) })
    }

    private var previewFooter: some View {
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(appState.selectedCandidateId?.capitalized ?? "—")
                    .font(Theme.ui(16, .semibold)).foregroundColor(Theme.ink)
                Spacer()
                // Zoom control (pinch or double-click also work).
                HStack(spacing: 6) {
                    Button(action: { appState.showMaskOverlay.toggle(); appState.onEdit() }) {
                        HStack(spacing: 4) {
                            Image(systemName: appState.showMaskOverlay ? "eye.fill" : "eye")
                                .font(.system(size: 10))
                            Text("Overlay")
                                .font(Theme.ui(10, appState.isOverlayShowing ? .semibold : .regular))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundColor(appState.isOverlayShowing ? Theme.glow : Theme.inkDim)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(
                            Capsule().fill(appState.isOverlayShowing ? Theme.glow.opacity(0.15) : Theme.surface2)
                                .overlay(Capsule().stroke(appState.isOverlayShowing ? Theme.glow.opacity(0.6) : Theme.hairline, lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Mask Overlay (O)")

                    Button(action: { appState.setZoom(appState.zoom - 0.5); zoomStart = appState.zoom }) {
                        Image(systemName: "minus.magnifyingglass").foregroundColor(Theme.inkDim)
                    }.buttonStyle(.plain)
                    Text("\(Int(appState.zoom * 100))%").font(Theme.mono(10)).foregroundColor(Theme.inkDim).frame(width: 40)
                    Button(action: { appState.setZoom(appState.zoom + 0.5); zoomStart = appState.zoom }) {
                        Image(systemName: "plus.magnifyingglass").foregroundColor(Theme.inkDim)
                    }.buttonStyle(.plain)
                    if appState.zoom > 1.01 {
                        Button(action: { appState.resetZoom(); zoomStart = 1 }) {
                            Text("Fit").font(Theme.ui(10, .semibold)).foregroundColor(Theme.glow)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                TemperatureLabel(appState: appState)
            }
            LiveTemperatureRail(appState: appState)
            // Craft self-check: each flagged problem gets a one-click Fix.
            //
            // Deliberately NOT animated. These flags appear and disappear as the craft check
            // re-runs behind a drag, so a transition here would be a row of warnings fading in and
            // out under the photograph the whole time a slider is moving.
            if !appState.activeCraftIssues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    // Only once there is more than one problem. With a single flag the button
                    // beside it says exactly what will happen, and "Fix all" would be the same
                    // click wearing a vaguer word.
                    if appState.activeCraftIssues.count > 1 {
                        HStack(spacing: 8) {
                            Image(systemName: "checklist")
                                .font(.system(size: 10)).foregroundColor(Theme.inkDim)
                            Text("\(appState.activeCraftIssues.count) craft flags")
                                .font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                            Spacer(minLength: 4)
                            Button(action: { appState.applyFixAll() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("Fix all").font(Theme.ui(10, .semibold))
                                }
                                .foregroundColor(Theme.base)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(Theme.glow))
                            }
                            .buttonStyle(.plain)
                            .disabled(appState.fixInProgress)
                            .opacity(appState.fixInProgress ? 0.45 : 1)
                            .animation(Motion.gated(Motion.quick, reduceMotion),
                                       value: appState.fixInProgress)
                            // "frame-wide", because subject flags are excluded by construction:
                            // `CraftFix.deferredForSubject` permanently defers .subjectFlat,
                            // .subjectTooDark and .subjectBlown, while this button appears whenever
                            // there is more than one flag of any kind. On a backlit portrait it was
                            // offering to fix flags it provably would not touch.
                            .help("Work through the frame-wide flags in one step, worst damage "
                                  + "first — clipping, then tone, then colour and skin. "
                                  + "Subject flags keep their own Fix.")
                        }
                    }
                    ForEach(appState.activeCraftIssues, id: \.self) { issue in
                        HStack(spacing: 8) {
                            // Theme.warn, not red: a craft flag is a question for the photographer,
                            // and it wears the same colour as the soft-focus marker in the strip.
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10)).foregroundColor(Theme.warn)
                            Text(issue.message).font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                            Spacer(minLength: 4)
                            // A FIX BUTTON IS A PROMISE. The subject corrections run into hard
                            // ceilings (±2 EV on the mask), and once one is spent, clicking again
                            // cannot do anything — which is precisely how "I click fix, it applies
                            // a change, I click again, and it never fixes" felt from the outside.
                            // So the button is withdrawn and the row says why instead.
                            if appState.canFix(issue) {
                                Button(action: { appState.applyFix(issue) }) {
                                    Text("Fix").font(Theme.ui(10, .semibold)).foregroundColor(Theme.base)
                                        .padding(.horizontal, 10).padding(.vertical, 3)
                                        .background(Capsule().fill(Theme.glow))
                                }
                                .buttonStyle(.plain)
                                .disabled(appState.fixInProgress)
                                .opacity(appState.fixInProgress ? 0.45 : 1)
                            } else {
                                Text("no fix").font(Theme.mono(9)).foregroundColor(Theme.inkDim)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().stroke(Theme.inkDim.opacity(0.35), lineWidth: 1))
                                    // Two different reasons wore one sentence. A subject flag with
                                    // no person segmentation never had a correction ATTEMPTED —
                                    // saying it "is already as far as it goes" describes a fix that
                                    // never ran. Live case, not a corner: Vision's face detector
                                    // fires on animals, so a cat portrait raises .subjectTooDark
                                    // with hasPerson false.
                                    .help(appState.hasPerson
                                          ? "\(Branding.displayName)'s automatic correction for this is already as far "
                                            + "as it goes — from here it's a manual adjustment"
                                          : "No subject \(Branding.displayName) can isolate in this frame — "
                                            + "this one needs a mask you draw")
                            }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                // The row SCROLLS rather than squeezing. Now that each label holds its own width
                // (see `toolbarLabel`), a narrow window would otherwise push the right-hand buttons
                // off the edge with no way to reach them. Export stays outside the scroller because
                // it is the one button that must never be the one that got pushed off.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                // Discoverable way to bring in a photo from a different folder. The filmstrip only
                // ever shows the folder you arrived from, so without this the only routes out were
                // ⌘O or a drag — neither of them visible.
                Button(action: appState.chooseAndOpen) { toolbarLabel("Open", filled: false) }
                    .buttonStyle(.plain)
                    .help("Open another photo or folder (⌘O)")
                Button(action: appState.closeCurrentPhoto) { toolbarLabel("Close", filled: false) }
                    .buttonStyle(.plain)
                    .help("Close this photo — your edit is saved")
                // Only when there is something to export. A button that reports "nothing edited yet"
                // is a button that exists to disappoint.
                if appState.isExporting {
                    Button(action: appState.cancelExport) {
                        toolbarLabel("Stop export", filled: false)
                    }
                    .buttonStyle(.plain)
                    .help("Stop after the frame being written. Files already written stay.")
                } else if !appState.exportScope().isEmpty {
                    Button(action: openExportEditedPanel) {
                        toolbarLabel(appState.exportButtonLabel, filled: false)
                    }
                    .buttonStyle(.plain)
                    .help(appState.exportEditedHelp)
                }
                // APPLYING A LOOK TO THE SHOOT NO LONGER ASKS FOR A FOLDER, because it no longer
                // writes anything into one. It sets the shoot's look — one record — and the strip
                // and canvas resolve it per frame from there. Export is what makes files, and it is
                // one button along.
                if appState.folderPhotos.count > 1 {
                    Button(action: { appState.applyLookToShoot() }) {
                        toolbarLabel(appState.applyButtonLabel, filled: false)
                    }
                    .buttonStyle(.plain)
                    .help(appState.applyButtonHelp)
                    // The Keep scope used to live in the batch panel's accessory. With no panel it
                    // has to be visible before the button is pressed, not after — and it is
                    // meaningless while frames are selected, because a selection IS the scope.
                    if appState.selectedPhotos.isEmpty && appState.keeperCount > 0 {
                        Toggle(isOn: $appState.batchKeepersOnly) {
                            Text("Kept only (\(appState.keeperCount))").font(Theme.ui(11))
                        }
                        .toggleStyle(.checkbox)
                        .foregroundColor(Theme.inkDim)
                        .help("Apply the look to just the \(appState.keeperCount) frame"
                              + "\(appState.keeperCount == 1 ? "" : "s") flagged Keep")
                    }
                    if appState.shootLook != nil {
                        Button(action: { appState.clearShootLook() }) {
                            toolbarLabel("Clear look", filled: false)
                        }
                        .buttonStyle(.plain)
                        .help("Take the look back off this shoot. Hand-made edits are left alone.")
                    }
                    if !appState.selectedPhotos.isEmpty {
                        Button(action: { appState.clearSelection() }) {
                            toolbarLabel("Deselect", filled: false)
                        }
                        .buttonStyle(.plain)
                        .help("Clear the strip selection — actions go back to covering the whole shoot")
                    }
                    // A background read is someone's fans spinning up. It says so, and it stops.
                    // Two wordings, because they are two promises: the sweep is "your whole shoot,
                    // because you pressed Apply"; the neighborhood is "the frames around where you
                    // are, so the next arrow key doesn't wait" — and its total re-baselines as you
                    // move, which without the words "ahead" read as a broken counter.
                    if appState.isReadingShoot {
                        Button(action: { appState.stopReadingShoot() }) {
                            toolbarLabel(appState.isSweepingShoot
                                ? "Reading the shoot \(appState.shootReadDone)/\(appState.shootReadTotal) — stop"
                                : "Reading ahead \(appState.shootReadDone)/\(appState.shootReadTotal) — stop",
                                         filled: false)
                        }
                        .buttonStyle(.plain)
                        .help(appState.isSweepingShoot
                              ? "Reading each frame now so export doesn't have to. Safe to stop — "
                                + "anything unread is simply read at export instead."
                              : "Reading the \(ReadAheadQueue.neighborhoodSize) frames around this one "
                                + "so the next arrow key doesn't wait. Safe to stop — a stopped "
                                + "read-ahead stays stopped until you Apply or change shoots.")
                    }
                }
                // Press and hold to see the untouched original. DragGesture(minimumDistance:0) is
                // a reliable press-and-hold (onLongPressGesture's `pressing` state is flaky).
                toolbarLabel(appState.showingOriginal ? "Original" : "Hold to compare",
                             filled: appState.showingOriginal)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !appState.showingOriginal { appState.showingOriginal = true } }
                        .onEnded { _ in appState.showingOriginal = false })
                // Holding against the ORIGINAL is one question; holding Kelvin's answers against
                // each other is the other one, and it is the question this app is for. It sits
                // next to its neighbour because they are the same gesture of the mind.
                if appState.canCompare {
                    Button { appState.toggleCompare() } label: {
                        toolbarLabel(appState.comparing ? "Comparing" : "Compare",
                                     filled: appState.comparing)
                    }
                    .buttonStyle(.plain)
                    .help("See Kelvin's interpretations side by side, large, and choose one. (C)")
                }
                    }
                    .padding(.trailing, 4)
                }
                Spacer(minLength: 0)
                // Only on frames that HAVE a position — most don't, and a checkbox governing
                // nothing reads as broken. Off means the shared file carries no GPS; camera and
                // exposure EXIF travel either way. Adjacent to Share rather than buried in a
                // panel, because a share has no panel and the choice must be visible before the
                // press, not discovered after the send.
                if appState.capture.location != nil {
                    Toggle(isOn: $appState.shareIncludeLocation) {
                        Text("Include location").font(Theme.ui(11))
                    }
                    .toggleStyle(.checkbox)
                    .foregroundColor(Theme.inkDim)
                    .help("Send this photo's GPS position along when sharing. Off, the shared "
                          + "file keeps the camera and exposure details but not where it was taken.")
                }
                Button(action: shareCurrentPhoto) {
                    // `toolbarLabel` with a spinner in front while the full-res render runs —
                    // the render is seconds, and a button that looks pressable during it invites
                    // the second press the guard then has to swallow.
                    HStack(spacing: 6) {
                        if appState.isPreparingShare {
                            ProgressView().controlSize(.small).tint(Theme.glow)
                        }
                        Text(appState.isPreparingShare ? "Rendering…" : "Share")
                            .font(Theme.ui(12, .semibold))
                            .foregroundColor(Theme.ink)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(
                        Capsule().fill(Theme.surface2)
                            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                    )
                    // Under the button, not beside it, so the services menu drops from the
                    // control the click landed on.
                    .background(ShareAnchor(presenter: sharePresenter))
                }
                .buttonStyle(.plain)
                .disabled(appState.isPreparingShare)
                // The size/format confession Export earned (its label reads "Export 2048 px" when
                // capped) extends to Share here: the shared file honours the SAME persisted export
                // settings, and a user who once exported small must not text small forever without
                // being told. Same fact, same place the eye goes for it.
                .help("Render this photo with its edit and hand it to Messages, AirDrop or Mail — "
                      + "as a \(appState.exportLongEdge > 0 ? "\(appState.exportLongEdge) px" : "full-resolution")"
                      + " .\(appState.exportFormat.fileExtension), the same file Export would write. "
                      + "The file goes to a temporary folder, never beside your originals.")
                Button(action: openExportPanel) {
                    toolbarLabel(appState.exportOneButtonLabel, filled: true)
                }
                    .buttonStyle(.plain)
                    .help(appState.exportOneButtonHelp)
            }
        }
        .padding(20)
        // Rim on the TOP edge here, unlike the header: this strip sits below the photograph, so the
        // lit edge is the one facing it. The light in this app always faces the picture.
        .glassSurface(edge: .top)
    }

    /// Deliberately still text-only, unlike every other button in this pass.
    ///
    /// Measured, these five pills already come to 557 pt and the preview pane is only 580 pt wide
    /// when the window is at its 940 pt minimum — and less than that once the splitter is dragged.
    /// A glyph each costs ~20 pt, which buys truncated labels at the app's own default size. An
    /// icon that pushes the word it is helping off the end of the button is not helping.
    private func toolbarLabel(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(Theme.ui(12, .semibold))
            .foregroundColor(filled ? Theme.base : Theme.ink)
            // ONE LINE, ALWAYS — the same rule as `lookChip`, and here it prevents something far
            // uglier. Narrow the window and SwiftUI squeezed these buttons rather than letting the
            // row overflow, so "Export full-res" wrapped to one character per line and the toolbar
            // became a wall of vertical text. A button's label is not a paragraph; it has one width
            // and the layout has to work around it.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(
                Capsule().fill(filled ? Theme.glow : Theme.surface2)
                    .overlay(Capsule().stroke(filled ? Color.clear : Theme.hairline, lineWidth: 1))
            )
    }

    static func bandColor(_ band: String) -> Color {
        switch band {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "aqua": return .cyan
        case "blue": return .blue
        case "purple": return .purple
        default: return Color(red: 1, green: 0.2, blue: 0.85)   // magenta
        }
    }

    /// What the camera recorded. Read-only — this is the photograph's own history, not something
    /// to edit, so it's presented as a record rather than as controls.
    private var capturePanel: some View {
        let c = appState.capture
        return VStack(alignment: .leading, spacing: 7) {
            if let camera = c.camera {
                Text(camera).font(Theme.ui(12, .medium)).foregroundColor(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lens = c.lens {
                Text(lens).font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = c.summaryText {
                Text(summary).font(Theme.mono(10)).foregroundColor(Theme.glow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let bias = c.exposureBiasText {
                Text("Exposure bias " + bias).font(Theme.mono(9)).foregroundColor(Theme.inkDim)
            }
            if let size = c.dimensionsText {
                Text(size).font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
            }
            if let date = c.captured {
                Text(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
                    .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
            }
            // SAY WHY THERE IS NO LOCATION, when the camera tried and failed. Silence here is
            // indistinguishable from the app not having looked — and on the shoot this was tested
            // against, all 110 frames were exactly this case.
            if c.locationText == nil, c.positionStatus == .void {
                Text("No position recorded — the camera wrote an empty GPS tag")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let location = c.locationText {
                // WHERE, AND A WAY OUT TO A MAP — deliberately as a hand-off rather than a map
                // drawn in this window.
                //
                // MapKit renders by fetching tiles from Apple, so an inline map would send this
                // photograph's coordinates off the machine every time you opened the panel. The
                // first line of CLAUDE.md is "Everything runs on-device. No cloud, no account, no
                // upload", and a location is the most sensitive single field in the file. Handing
                // off means Kelvin itself never makes the request: nothing leaves until you click,
                // and then it is Maps doing it, visibly, because you asked.
                //
                // Which is also why the button says "Show in Maps" instead of just being a
                // clickable coordinate. An affordance that quietly leaves the app is the thing
                // being avoided here.
                VStack(alignment: .leading, spacing: 3) {
                    // The name first when there is one, the degrees underneath it always. The name
                    // is a lookup that can fail or be switched off (D14); the coordinate is what the
                    // camera actually recorded, and it never stops being the ground truth.
                    // SEVERAL LINES, not one guessed name. No single placemark field is reliably
                    // the answer — at Sunriver, `locality` says "Bend", `areasOfInterest` says
                    // "Deschutes National Forest", and "Sunriver" is in none of them. Showing the
                    // town, the feature, the road and the postcode lets a photographer recognise
                    // the place from whichever of those they know.
                    if let detail = appState.capture.location
                        .flatMap({ PlaceNames.shared.cachedDetail(for: $0) }) {
                        Text(detail.name).font(Theme.ui(11, .medium)).foregroundColor(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        let extras = [detail.area, detail.street, detail.postalCode].compactMap { $0 }
                        if !extras.isEmpty {
                            Text(extras.joined(separator: " · "))
                                .font(Theme.mono(9)).foregroundColor(Theme.inkDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(location).font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                        .textSelection(.enabled)
                    // THE MAP IS DRAWN HERE, not handed off to Maps.app.
                    //
                    // It was a "Show in Maps" link, on the reasoning that an inline map would send
                    // coordinates to Apple and the app made no calls. D14 changed that premise —
                    // place names already ask Apple where this is — so the honest question became
                    // which kind of map, and the answer is a STILL one. An interactive `Map` streams
                    // tiles for wherever it is panned, for as long as the panel is open; a snapshot
                    // asks once for one fixed frame and is cached. Same shape of request as the name
                    // beside it, governed by the same switch.
                    if let point = c.location, let map = PlaceMaps.shared.image(for: point) {
                        // The still map answers "where", and clicking it hands off to Maps for the
                        // things a still cannot do — panning out, switching to satellite, getting
                        // directions. Inline for the glance, Maps for the exploration.
                        let picture = Image(nsImage: map)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.hairline.opacity(0.8), lineWidth: 1))
                        if let url = c.mapURL {
                            Link(destination: url) { picture }
                                .buttonStyle(.plain)
                                .help("Open this location in Maps")
                                .accessibilityLabel(PlaceNames.shared.cachedName(for: point)
                                                    .map { "Map of \($0). Opens in Maps." }
                                                    ?? "Map of where this was taken. Opens in Maps.")
                        } else {
                            picture
                        }
                    }
                }
            }
            // WHAT THE MODEL SAW, in its own words, with the rest of the facts about the photograph
            // rather than buried under the candidates.
            //
            // It reads as a caption because that is what it is, and it is the text that would go
            // into a delivered file's description field if that ever ships. Marked as a reading
            // rather than presented as fact: everything else in this panel was recorded by the
            // camera, and this one line was guessed by a 2B model.
            if let note = appState.perception?.notes, !note.isEmpty {
                Divider().overlay(Theme.hairline.opacity(0.5)).padding(.vertical, 2)
                Text(note)
                    .font(Theme.ui(11))
                    .foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("KELVIN'S READING")
                    .font(Theme.mono(8)).tracking(1.2).foregroundColor(Theme.inkFaint)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Selectable HERE and not app-wide: enabling it globally let text selection swallow
        // clicks meant for buttons and sliders. This panel is the one place with values worth
        // pasting somewhere else — a lens name, coordinates, the pixel dimensions.
        .textSelection(.enabled)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline.opacity(0.6), lineWidth: 1))
        )
    }

    private func lookChip(_ look: LookPreset) -> some View {
        let on = appState.activeLookId == look.id
        return Button(action: { appState.applyLook(on ? nil : look.id) }) {
            Text(look.name)
                .font(Theme.ui(11, on ? .semibold : .regular))
                .foregroundColor(on ? Theme.base : Theme.ink)
                // ONE LINE, ALWAYS. Narrow the panel and "Golden hour", "Chrome slide" and
                // "Vintage warm" wrapped *inside* their capsules, so those chips became two lines
                // tall while their neighbours stayed one — a row of pills at two different heights,
                // which reads as a layout fault rather than a narrow panel. `FlowRow` already knows
                // how to move a chip to the next row; the chip's job is to have one honest width and
                // let it.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(
                    Capsule().fill(on ? Theme.glow : Theme.surface2)
                        .overlay(Capsule().stroke(on ? Color.clear : Theme.hairline, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        // The chip settling into "on" is the same class of feedback as a candidate becoming
        // selected, and wears the same 0.14s.
        .animation(Motion.gated(Motion.quick, reduceMotion), value: on)
        .help(look.blurb)
    }

    private func editToolLabel(_ text: String, enabled: Bool, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(Theme.ui(11, .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundColor(enabled ? Theme.ink : Theme.inkFaint)
        // Tighter than the 12 it was. Three of these — Undo, Redo, Reset sliders — sit on one row,
        // and at a 280 pt panel the horizontal padding is the difference between the row fitting and
        // the row being clipped.
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(Theme.surface2.opacity(enabled ? 1 : 0.4))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))
        )
    }

    /// The mask buttons are a 3×3 grid of near-identical capsules, and "+ Luma" next to "+ Skin"
    /// next to "+ Colour" is a paragraph to be read rather than a palette to be reached into. The
    /// glyph says what kind of selection you are about to make; the word stays because a picture
    /// of a mask type is not a name for one.
    static func addMaskLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Theme.inkDim)
            Text(text)
                .font(Theme.ui(11, .semibold)).foregroundColor(Theme.ink)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface2)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
        )
    }

    private var sidebar: some View {
        let ch = appState.onEdit   // re-render on any slider change
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HistogramHost(preview: appState.preview)

                // DIRECTLY UNDER THE HISTOGRAM, which is where the facts about a photograph belong:
                // the two things here that are not controls, together, above everything you reach
                // for. It sat last, below the entire mask kit, and was reported as "collapsed by
                // default" when it had been `defaultOpen: true` all along — nine sections and a long
                // scroll between the photograph and the facts about it is indistinguishable from
                // being folded away. Position was the bug, not the fold state.
                if appState.capture.camera != nil || appState.capture.summaryText != nil
                    || appState.perception != nil {
                    CollapsibleSection("Photo", icon: "camera", defaultOpen: true) { capturePanel }
                }

                HStack(spacing: 8) {
                    Button(action: appState.undo) { editToolLabel("Undo", enabled: appState.canUndo, icon: "arrow.uturn.backward") }
                        .buttonStyle(.plain).disabled(!appState.canUndo)
                        .keyboardShortcut("z", modifiers: .command)
                    Button(action: appState.redo) { editToolLabel("Redo", enabled: appState.canRedo, icon: "arrow.uturn.forward") }
                        .buttonStyle(.plain).disabled(!appState.canRedo)
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                    Spacer()
                    // "Reset sliders", not "Reset all": `resetToCandidate` restores the global
                    // adjustments, straighten, HSL, the look and the auto-mask dictionaries — and
                    // deliberately leaves hand-drawn masks and dust removal alone. Three brush masks
                    // surviving a button called "Reset all" is a broken promise; renaming the button
                    // is the honest fix, because silently deleting someone's masks would be worse.
                    Button(action: appState.resetToCandidate) { editToolLabel("Reset sliders", enabled: true, icon: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                }

                Group {
                CollapsibleSection("Candidates", icon: "rectangle.stack", defaultOpen: true) {
                // WHAT IT SAW, above what it proposes — so the panel reads as a chain of reasoning
                // rather than four options from nowhere.
                //
                // This is the app's only account of itself. Everything below is computed from the
                // read: if a candidate comes out wrong, this is what tells you whether the READ was
                // wrong ("golden hour" on an overcast morning) or the MAPPING was (a correct read
                // turned into the wrong numbers). Those are entirely different bugs and, without
                // this, indistinguishable from the outside.
                if let seen = appState.sceneSummary {
                    // The CATEGORICAL read only. The model's sentence moved up to the Photo panel
                    // with the rest of the facts about the photograph, and printing it in both
                    // places put the same line on screen twice, forty points apart.
                    //
                    // What stays here is what earns its place here: these are the tokens the engine
                    // actually branched on, so they explain why THESE four candidates and not others.
                    Text(seen.headline)
                        .font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                }
                if appState.candidates.isEmpty {
                    // Say what's happening instead of leaving a hole. The photo is already on
                    // screen, so this is the only part still pending.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the scene…")
                            .font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                    }
                    .padding(.vertical, 6)
                }
                VStack(spacing: 8) {
                    ForEach(appState.candidates) { candidate in
                        CandidateRow(candidate: candidate,
                                     isSelected: candidate.id == appState.selectedCandidateId) {
                            appState.selectCandidate(id: candidate.id)
                        }
                    }
                }
                }

                CollapsibleSection("Looks", icon: "camera.filters", trailing: appState.activeLookId == nil ? nil : "On") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(LookPreset.Group.allCases, id: \.self) { group in
                        let looks = LookPreset.library.filter { $0.group == group }
                        if !looks.isEmpty {
                            Text(group.rawValue.uppercased())
                                .font(Theme.mono(9)).tracking(1.4).foregroundColor(Theme.inkFaint)
                            FlowRow(looks.map(\.id)) { id in
                                if let look = LookPreset.named(id) {
                                    lookChip(look)
                                }
                            }
                        }
                    }
                    if appState.activeLookId != nil {
                        Button(action: { appState.applyLook(nil) }) {
                            Text("Clear look").font(Theme.ui(10, .semibold)).foregroundColor(Theme.inkDim)
                        }.buttonStyle(.plain)
                    }
                }
                }

                // LIGHT — white balance and tone together. They are one decision: how the frame
                // is exposed and coloured by its light source. Open by default because this is
                // what gets touched on essentially every photograph.
                CollapsibleSection("Light", icon: "sun.max", defaultOpen: true) {
                    LightSliders(appState: appState)
                }

                }
                Group {
                CollapsibleSection("Presence", icon: "sun.haze") {
                    PresenceSliders(appState: appState)
                }

                // COLOUR — the global pair and the per-colour mixer are the same decision at two
                // levels of detail, so they live together rather than as two headings.
                CollapsibleSection("Colour", icon: "paintpalette") {
                    ColourSliders(appState: appState)
                }

                CollapsibleSection("Geometry", icon: "crop.rotate") {
                    GeometrySliders(appState: appState)
                }

                CollapsibleSection("Masks", icon: "circle.dashed", trailing: appState.maskCountLabel) {
                VStack(spacing: 12) {
                    // The subjects Kelvin found, first — before the shapes you have to draw
                    // yourself. Picking a thing out of a list is the cheap path and it should be
                    // the one you meet first; the geometry below is the fallback for when the
                    // segmentation has not found what you meant.
                    if !appState.subjectInstances.isEmpty {
                        SubjectList(instances: appState.subjectInstances,
                                    maskedIds: appState.maskedInstanceIds,
                                    highlighted: $appState.highlightedInstanceId,
                                    onPick: appState.addInstanceMask)
                        // Point at the thing instead of reading its row. "Subject 2" names nothing
                        // until you have found it on the photograph, and by then you could have
                        // clicked it.
                        Button {
                            appState.pickingInstance.toggle()
                        } label: {
                            ContentView.addMaskLabel(appState.pickingInstance
                                         ? "Click a subject on the photo… (esc)"
                                         : "Select a subject on the photo",
                                         icon: "hand.point.up.left")
                        }
                        .buttonStyle(.plain)
                        .help("Click something in the picture to mask it. \(Branding.displayName) only finds "
                              + "subjects that stand out from their background.")
                    }
                    // Auto-detected masks (subject / sky): toggle + strength.
                    ForEach(appState.baseMaskIds, id: \.self) { mid in
                        MaskControl(
                            name: mid.capitalized,
                            isOn: Binding(get: { appState.maskEnabled[mid] ?? true },
                                          set: { appState.maskEnabled[mid] = $0 }),
                            strength: Binding(get: { appState.maskStrength[mid] ?? 100 },
                                              set: { appState.maskStrength[mid] = $0 }),
                            onChange: appState.onEdit,
                            maskId: mid,
                            adjustment: { key in appState.maskAdjustmentBinding(mid, key) },
                            feather: appState.maskFeatherBinding(mid),
                            tightness: appState.maskTightnessBinding(mid),
                            invert: appState.maskInvertBinding(mid),
                            onReset: { appState.resetMask(mid) },
                            // Selectable, like every other mask. Without this an auto mask could
                            // be shown by the overlay but never named by the selection, so the
                            // sky came up red with nothing to click and no way to clear it.
                            isSelected: appState.selectedMask == .auto(mid),
                            onSelect: {
                                // The eye is "show me this one", so it arms the overlay as well as
                                // selecting. Clicking the same eye again clears the selection, and
                                // with nothing selected the overlay draws nothing — which is the
                                // off switch the auto masks never had.
                                if appState.selectedMask == .auto(mid) {
                                    appState.selectedMask = nil
                                } else {
                                    appState.selectedMask = .auto(mid)
                                    appState.showMaskOverlay = true
                                }
                                appState.onEdit()
                            },
                            onAdjustBegin: { appState.isAdjustingMaskTone = true },
                            onAdjustEnd: { appState.isAdjustingMaskTone = false; appState.onEdit() })
                    }
                    // Hand-drawn masks: gradient geometry or brush strokes + local adjustments.
                    // Identity bindings, not `ForEach($appState.userMasks)` — see
                    // `userMaskBinding(fallback:)` for the crash the element bindings caused.
                    ForEach(appState.userMasks) { m in
                        UserMaskEditor(
                            mask: appState.userMaskBinding(fallback: m), onChange: appState.onEdit,
                            onDelete: { appState.removeUserMask(m.id) },
                            isSelected: appState.selectedUserMaskId == m.id,
                            // `onEdit()` is what rebuilds the render, and the render is what
                            // chooses the overlay bitmap — without it the red stayed on the
                            // previously selected mask until you happened to nudge a slider.
                            onSelect: { appState.selectedUserMaskId = m.id; appState.onEdit() },
                            onToggleSelected: { appState.toggleMaskSelection(m.id) },
                            isPainting: appState.paintingMaskId == m.id,
                            togglePaint: { appState.paintingMaskId = (appState.paintingMaskId == m.id) ? nil : m.id },
                            clearStrokes: { appState.clearStrokes(m.id) },
                            brushRadius: Binding(get: { appState.brushRadius },
                                                 set: { appState.brushRadius = $0 }),
                            brushMode: Binding(get: { appState.brushErases },
                                               set: { appState.brushErases = $0 }),
                            isSeeding: appState.seedingMaskId == m.id,
                            toggleSeeding: {
                                appState.seedingMaskId = (appState.seedingMaskId == m.id) ? nil : m.id
                            },
                            hasPerson: appState.hasPerson,
                            subjectIsPerson: appState.subjectIsPerson,
                            hasSky: appState.hasSky,
                            people: appState.subjectInstances.filter { $0.kind == .person },
                            onSavePreset: { appState.promptSaveMaskPreset(m) },
                            onAdjustBegin: { appState.isAdjustingMaskTone = true },
                            onAdjustEnd: { appState.isAdjustingMaskTone = false },
                            canMoveUp: appState.userMasks.first?.id != m.id,
                            canMoveDown: appState.userMasks.last?.id != m.id,
                            onMoveUp: { appState.moveUserMask(m.id, by: -1) },
                            onMoveDown: { appState.moveUserMask(m.id, by: 1) })
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        // The "+" used to be repeated on all eight buttons. Said once over the
                        // grid it costs a line and buys every button back the width its glyph
                        // needs — and the row stops reading as a list of things called "+ Luma".
                        Text("ADD A MASK — PICK WHAT DEFINES THE REGION")
                            .font(Theme.mono(9)).tracking(1.4).foregroundColor(Theme.inkFaint)
                        HStack(spacing: 6) {
                            Button(action: { appState.addUserMask(.radial) }) { ContentView.addMaskLabel("Radial", icon: "circle.circle") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.linear) }) { ContentView.addMaskLabel("Grad", icon: "rectangle.tophalf.filled") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.brush) }) { ContentView.addMaskLabel("Brush", icon: "paintbrush") }.buttonStyle(.plain)
                        }
                        HStack(spacing: 6) {
                            Button(action: { appState.addUserMask(.colorRange) }) { ContentView.addMaskLabel("Colour", icon: "eyedropper") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.luminance) }) { ContentView.addMaskLabel("Luma", icon: "circle.lefthalf.filled") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.skin) }) { ContentView.addMaskLabel("Skin", icon: "face.smiling") }.buttonStyle(.plain)
                        }
                        HStack(spacing: 6) {
                            Button(action: { appState.addUserMask(.subject) }) { ContentView.addMaskLabel("Subject", icon: "person.fill") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.background) }) { ContentView.addMaskLabel("Background", icon: "photo") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.sky) }) { ContentView.addMaskLabel("Sky", icon: "cloud.sun") }.buttonStyle(.plain)
                        }
                        // The wand sits beside Colour rather than with the automatic masks, because
                        // that is what it is the other half of: Colour takes every matching pixel in
                        // the frame, the wand takes the one connected thing you point at. It is the
                        // answer for everything Vision will not segment — a sea stack, a headland,
                        // a wall — which is most of a landscape.
                        HStack(spacing: 6) {
                            Button(action: { appState.addUserMask(.wand) }) { ContentView.addMaskLabel("Wand", icon: "wand.and.stars") }.buttonStyle(.plain)
                            Spacer(minLength: 0)
                        }
                        // Presets: the same masks with the settings already in them. Built-ins
                        // ship a few honest starting points; the star of the show is "save as
                        // preset" on any mask you have tuned, which lands in these menus.
                        Text("OR START FROM A PRESET")
                            .font(Theme.mono(9)).tracking(1.4).foregroundColor(Theme.inkFaint)
                            .padding(.top, 4)
                        HStack(spacing: 6) {
                            ForEach(MaskPreset.grouped(withCustom: appState.customMaskPresets), id: \.label) { group in
                                Menu {
                                    ForEach(group.presets) { preset in
                                        Button(preset.name) { appState.addPresetMask(preset) }
                                    }
                                    let customs = group.presets.filter { !$0.builtIn }
                                    if !customs.isEmpty {
                                        Divider()
                                        Menu("Remove a saved preset") {
                                            ForEach(customs) { preset in
                                                Button(preset.name, role: .destructive) {
                                                    appState.deleteMaskPreset(preset.id)
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    ContentView.addMaskLabel(group.label, icon: group.icon)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                            }
                        }
                    }
                }
                // A new mask panel is tall, and it lands above the buttons you just clicked, which
                // pushes them down the panel. Fading it in over the layout move is the difference
                // between "where did the buttons go" and seeing what arrived. Keyed on the COUNT:
                // adjusting a mask must never animate anything.
                .animation(Motion.gated(Motion.quick, reduceMotion), value: appState.userMasks.count)
                }

                CollapsibleSection("Repair", icon: "bandage",
                                   trailing: appState.healSpots.isEmpty ? nil
                                           : "\(appState.healSpots.count) healed") {
                // The tool is a mode, so it says plainly whether it has the canvas. The old control
                // here was a switch that patched whatever a detector had found; the detector never
                // worked (see `SpotHeal`), so the switch was the "appears to work and does nothing"
                // failure. Pointing at the blemish yourself is the part that always worked.
                Toggle(isOn: $appState.healToolActive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Heal tool").font(Theme.ui(13, .medium)).foregroundColor(Theme.ink)
                        Text(appState.healToolActive
                             ? "Click a blemish to patch it from nearby pixels"
                             : "Touch up dust, specks and small distractions")
                            .font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                    }
                }
                .toggleStyle(.switch).tint(Theme.glow)

                if appState.healToolActive {
                    ToneSlider(label: "Heal size",
                               value: Binding(get: { appState.healRadius },
                                              set: { appState.healRadius = $0 }),
                               range: 0.003...0.08, step: 0.001, unit: "",
                               onChange: {}, neutral: 0.012)
                    Text("[ and ] resize · ⌥-click a patch to remove it")
                        .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                }

                if !appState.healSpots.isEmpty {
                    HStack {
                        Text("\(appState.healSpots.count) spot\(appState.healSpots.count == 1 ? "" : "s") healed")
                            .font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                        Spacer()
                        Button("Clear all") { appState.clearHealSpots() }
                            .buttonStyle(.plain).controlSize(.small)
                            .font(Theme.ui(11)).foregroundColor(Theme.inkDim)
                    }
                    Text("⌘Z undoes the last one · hold Compare to see them back")
                        .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                }
                }

                }
            }
            .padding(20)
        }
    }

    /// A sidebar section that can be folded away, remembering its state between launches.
    ///
    /// The panel had eleven sections stacked in one scroll, every one of them always open. Most of
    /// them are not touched on most photos, so reaching the ones that are meant scrolling past the
    /// rest — and the sheer wall of controls is the thing that makes an editor feel heavy. Folded
    /// by default, the panel shows what you actually reach for and hides the rest until asked.
    private struct CollapsibleSection<Content: View>: View {
        let title: String
        /// One SF Symbol per section. Folded, the panel is nine near-identical rows of tracked-out
        /// capitals; a glyph gives each row a silhouette, so the section you want is found by shape
        /// before the word is read. It is drawn faint and fixed-width on purpose — a label that has
        /// to compete with its own icon has been made harder to read, not easier.
        let icon: String
        var trailing: String?
        var accent: Bool = false
        @AppStorage private var isOpen: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ViewBuilder let content: () -> Content

        init(_ title: String, icon: String, trailing: String? = nil, accent: Bool = false,
             defaultOpen: Bool = false, @ViewBuilder content: @escaping () -> Content) {
            self.title = title
            self.icon = icon
            self.trailing = trailing
            self.accent = accent
            // Keyed by title so a section keeps its state across launches. Sections a photographer
            // opens once tend to be ones they want open every time.
            self._isOpen = AppStorage(wrappedValue: defaultOpen, "sidebar.section.\(title)")
            self.content = content
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(Motion.gated(Motion.quick, reduceMotion)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.inkFaint)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .foregroundColor(isOpen ? Theme.inkDim : Theme.inkFaint)
                            // Fixed width so every title starts on the same left edge whatever the
                            // glyph is; the column of words has to stay a column.
                            .frame(width: 13)
                        Text(title.uppercased())
                            .font(Theme.mono(10, .semibold)).tracking(2)
                            .foregroundColor(isOpen ? Theme.ink : Theme.inkDim)
                        Spacer()
                        if let trailing {
                            Text(trailing.uppercased())
                                .font(Theme.mono(9, .semibold)).tracking(1.5)
                                .foregroundColor(Theme.glow)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.glow.opacity(0.14)))
                        }
                    }
                    .contentShape(Rectangle())    // the whole row is the target, not just the text
                }
                .buttonStyle(.plain)

                // Fade rather than slide: the section below is already moving to make room, and
                // two things travelling at once for one click is one too many.
                if isOpen { content().transition(.opacity) }
            }
        }
    }

    private func sectionLabel(_ text: String, trailing: String?) -> some View {
        HStack {
            Text(text.uppercased())
                .font(Theme.mono(10, .semibold)).tracking(2).foregroundColor(Theme.inkDim)
            Spacer()
            if let trailing {
                Text(trailing.uppercased())
                    .font(Theme.mono(9, .semibold)).tracking(1.5)
                    .foregroundColor(Theme.glow)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.glow.opacity(0.14)))
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(Theme.mono(30, .medium)).foregroundColor(color)
            Text(label.uppercased()).font(Theme.mono(9)).tracking(1.5).foregroundColor(Theme.inkDim)
        }
    }

    // MARK: File panels

    /// Render, then hand the file to the system picker. No panel in between: the render decides
    /// nothing a panel would ask, and its failure modes already speak through the status line.
    private func shareCurrentPhoto() {
        Task {
            if let url = await appState.renderCurrentPhotoForSharing() {
                // Wired per share, so the callback always closes over the CURRENT app state.
                sharePresenter.onDidChoose = { [weak appState] in
                    guard let appState,
                          appState.imageURL == appState.pendingSharePickURL else { return }
                    appState.recordCurrentPick()
                }
                sharePresenter.present([url])
            }
        }
    }

    private func openExportPanel() {
        let panel = NSSavePanel()
        // The format the popup is currently set to, not a fixed pair. Hard-coded to [.jpeg, .png],
        // the panel renamed a HEIC or 16-bit TIFF export to `.jpeg` on the way out while
        // `ImageWriter` went on encoding the chosen format into it. Kept in step from
        // `ExportTarget.refresh` for every later change to the popup.
        panel.allowedContentTypes = [appState.exportFormat.contentType]
        // Suggest a name that says what the photo IS — still fully editable in the panel.
        panel.nameFieldStringValue = appState.suggestedExportName(ext: appState.exportFormat.fileExtension)
        // The one thing about an export that is not visible in the file you get back.
        //
        // In the panel rather than in the sidebar, because it is a property of THIS export and the
        // moment you are deciding it is the moment you are choosing where the file goes. It also
        // covers the batch, which writes hundreds of files from the same setting — so the checkbox
        // that says what travels has to be somewhere you meet before either.
        panel.accessoryView = PanelAccessories.exportOptions(appState, savePanel: panel)

        // OPEN BESIDE THE PHOTOGRAPH, IN ITS OWN "Edited" FOLDER.
        //
        // This used to open wherever the save panel happened to have been last, which for a shoot
        // opened from a card is somewhere else entirely — an export from Tuesday's job landing in
        // Monday's folder is the kind of mistake nobody notices until a client does. The answer a
        // photographer wants nine times in ten is "next to the originals, but not among them", and
        // it is the same answer the group export already gives.
        //
        // The folder has to exist for `directoryURL` to point at it, so it is created here rather
        // than at write time — and removed again below if the export is cancelled and nothing
        // landed in it, because a folder that appears merely because you opened a panel and
        // changed your mind is litter.
        var createdFolder: URL?
        if let source = appState.imageURL?.deletingLastPathComponent() {
            let edited = source.appendingPathComponent(Branding.exportFolderName, isDirectory: true)
            if !FileManager.default.fileExists(atPath: edited.path) {
                if (try? FileManager.default.createDirectory(at: edited,
                                                             withIntermediateDirectories: true)) != nil {
                    createdFolder = edited
                }
            }
            if FileManager.default.fileExists(atPath: edited.path) { panel.directoryURL = edited }
        }

        let choice = panel.runModal()
        // Only a folder THIS call created, and only while it is still empty. Never a folder that
        // was already there, and never one the export has just written into.
        if let createdFolder,
           (try? FileManager.default.contentsOfDirectory(atPath: createdFolder.path))?.isEmpty == true,
           choice != .OK {
            try? FileManager.default.removeItem(at: createdFolder)
        }
        if choice == .OK, let url = panel.url {
            Task { await appState.exportFullResolution(to: url) }
        }
    }

    /// Where the edited photographs go.
    ///
    /// A save panel rather than a folder chooser, so the destination arrives PRE-NAMED and visible:
    /// it opens on the shoot's own folder with "Edited" already typed. The principle is that nothing
    /// is ever written somewhere the user has not seen named — but they should not have to type it
    /// either, and the answer is the same nine times in ten.
    ///
    /// Writing into the shoot's own folder is refused downstream by `Destination.prepare`, which
    /// compares filesystem identity; a subfolder is safe and the originals cannot be touched.
    private func openExportEditedPanel() {
        let panel = NSSavePanel()
        panel.title = "Export edited photos"
        panel.message = "Choose a folder for the edited copies. Your originals are never modified."
        panel.nameFieldLabel = "Folder:"
        // The same constant the single-photo export opens into, so exporting one frame and then the
        // whole shoot puts both in one place rather than in "Edited" and "Edits".
        panel.nameFieldStringValue = Branding.exportFolderName
        panel.canCreateDirectories = true
        if let folder = appState.imageURL?.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        panel.accessoryView = PanelAccessories.exportOptions(appState, showScope: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        appState.startExport(to: target)
    }
}

// MARK: - Candidate row


// MARK: - Slider sections
//
// Each section is its own View, and the reason is invalidation rather than tidiness. SwiftUI
// re-evaluates a body when something it READ has changed; with these inline in `sidebar`, the
// sidebar — and through it the whole of `ContentView.body`, the footer and the filmstrip — read
// `appState.edit`, and every tick of every slider drag rebuilt the entire window. Measured during an
// automated drag: the window's body evaluation and layout were most of a 170 ms stall per tick. Each
// of these reads the edit state on its own, so a tick invalidates the one section being dragged.

private struct LightSliders: View {
    @Bindable var appState: AppState
    var body: some View {
        VStack(spacing: 14) {
            ToneSlider(label: "Temp", value: appState.temperatureBinding, range: 2500...9500, step: 10, unit: " K", onChange: appState.onEdit, identity: .temperature, neutral: 6500)
            ToneSlider(label: "Tint", value: $appState.edit.tint, range: -100...100, step: 1, unit: "", onChange: appState.onEdit, identity: .tint)
            Divider().overlay(Theme.hairline).padding(.vertical, 2)
            ToneSlider(label: "Exposure", value: $appState.edit.exposureEV, range: -5...5, step: 0.05, unit: " EV", onChange: appState.onEdit, identity: .exposure)
            ToneSlider(label: "Contrast", value: $appState.edit.contrast, range: -100...100, step: 1, unit: "", onChange: appState.onEdit, identity: .contrast)
            // RECOVERY ONLY, exactly as the masked version already is. `CIHighlightShadowAdjust`
            // documents its highlight amount as 0…1 with 1.0 meaning no change, so the
            // renderer's `1.0 + highlights/100` clamps for every positive value and does
            // nothing — measured at ΔE 0.0 when this was found on the mask panel. The
            // global slider went through byte-identical code and was left at full range,
            // so half its travel moved a number and not the photograph.
            ToneSlider(label: "Highlight recovery", value: $appState.edit.highlights, range: -100...0, step: 1, unit: "", onChange: appState.onEdit, identity: .highlights)
            ToneSlider(label: "Shadows", value: $appState.edit.shadows, range: -100...100, step: 1, unit: "", onChange: appState.onEdit, identity: .shadows)
            ToneSlider(label: "Whites", value: $appState.edit.whites, range: -100...100, step: 1, unit: "", onChange: appState.onEdit, identity: .highlights)
            ToneSlider(label: "Blacks", value: $appState.edit.blacks, range: -100...100, step: 1, unit: "", onChange: appState.onEdit, identity: .shadows)
        }
    }
}

private struct PresenceSliders: View {
    @Bindable var appState: AppState
    var body: some View {
        VStack(spacing: 14) {
            ToneSlider(label: "Texture", value: $appState.edit.texture, range: -100...100, step: 1, unit: "", onChange: appState.onEdit, identity: .presence)
            ToneSlider(label: "Clarity", value: $appState.edit.clarity, range: -100...100, step: 1, unit: "", onChange: appState.onEdit, identity: .presence)
            ToneSlider(label: "Dehaze", value: $appState.edit.dehaze, range: 0...100, step: 1, unit: "", onChange: appState.onEdit, identity: .presence)
            // Fusion lives in Presence but is not one: it opens the shadows and holds the
            // highlights, so it wears the shadow rail rather than the haze one.
            ToneSlider(label: "Fusion", value: $appState.edit.fusion, range: 0...100, step: 1, unit: "", onChange: appState.onEdit, identity: .shadows)
        }
    }
}

private struct ColourSliders: View {
    @Bindable var appState: AppState
    var body: some View {
        VStack(spacing: 14) {
            ToneSlider(label: "Vibrance", value: $appState.edit.vibrance, range: -100...100, step: 1, unit: "", onChange: appState.onEdit, identity: .saturation(hue: nil))
            ToneSlider(label: "Saturation", value: $appState.edit.saturation, range: -100...100, step: 1, unit: "", onChange: appState.onEdit, identity: .saturation(hue: nil))
        }
        VStack(spacing: 12) {
            Divider().overlay(Theme.hairline).padding(.vertical, 2)
            HStack(spacing: 6) {
                ForEach(appState.hslBands, id: \.self) { band in
                    Circle().fill(ContentView.bandColor(band))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(appState.hslBand == band ? Theme.ink : Theme.hairline,
                                                 lineWidth: appState.hslBand == band ? 2.5 : 1))
                        .overlay(Circle().stroke(.white.opacity(appState.hsl[band] != nil ? 0.9 : 0), lineWidth: 1).padding(3))
                        .onTapGesture { appState.hslBand = band }
                }
            }
            // The mixer's rails follow the selected band, so the panel shows which colour is
            // under the knife — the swatch row above says which band, not what it does.
            ToneSlider(label: "Hue", value: appState.hslBinding(\.h), range: -100...100, step: 1, unit: "", onChange: appState.onEdit,
                       identity: .hueShift(center: ToneIdentity.bandHue(appState.hslBand)))
            ToneSlider(label: "Saturation", value: appState.hslBinding(\.s), range: -100...100, step: 1, unit: "", onChange: appState.onEdit,
                       identity: .saturation(hue: ToneIdentity.bandHue(appState.hslBand)))
            ToneSlider(label: "Luminance", value: appState.hslBinding(\.l), range: -100...100, step: 1, unit: "", onChange: appState.onEdit, identity: .exposure)
        }
    }
}

private struct GeometrySliders: View {
    @Bindable var appState: AppState
    var body: some View {
        VStack(spacing: 12) {
            ToneSlider(label: "Straighten", value: $appState.straighten, range: -15...15, step: 0.1, unit: "°", onChange: appState.onEdit)
            Button(action: appState.autoStraighten) { ContentView.addMaskLabel("Auto-level horizon", icon: "level") }
                .buttonStyle(.plain)
        }
    }
}

/// The footer's temperature readout, as its own view for the reason the slider sections are: it
/// reads `activeTemperature`, which moves on every tick of a temperature drag, and read inline it
/// took the whole of `ContentView.body` with it on every one.
private struct TemperatureLabel: View {
    @Bindable var appState: AppState
    var body: some View {
        let temp = appState.activeTemperature
        Text(temp.map { "\(Int($0)) K" } ?? "as-shot")
            .font(Theme.mono(12))
            .foregroundColor(temp.map(KelvinScale.color) ?? Theme.inkDim)
    }
}

/// Same reasoning, for the rail under it.
private struct LiveTemperatureRail: View {
    @Bindable var appState: AppState
    var body: some View {
        TemperatureRail(marks: appState.activeTemperature.map { [($0, true)] } ?? [])
    }
}

struct CandidateRow: View {
    let candidate: CandidateViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var temp: Double? { candidate.baseRecipe.global.temperatureK }

    /// What makes THIS candidate different from the others, in at most three numbers.
    ///
    /// The row used to show exposure and nothing else, which made four genuinely different options
    /// describe themselves identically: `RecipeEngine.exposure` deliberately returns exactly zero for
    /// any frame whose median luma sits between 0.30 and 0.60 — "leave a reasonably-exposed frame
    /// alone" — and that band covers most competently exposed photographs. So the picker was
    /// reporting the one value designed not to move, while the contrast and vibrance that actually
    /// separate Natural from Dramatic went unmentioned.
    ///
    /// Ordered by how much a photographer would notice, not by magnitude: exposure first when it is
    /// doing anything, then contrast, then colour. Empty means this candidate really is a no-op,
    /// which is worth saying out loud rather than dressing up as "+0.00 EV".
    private var signature: String {
        let g = candidate.baseRecipe.global
        var parts: [String] = []
        if abs(g.exposureEV) >= 0.01 { parts.append(String(format: "%+.2f EV", g.exposureEV)) }
        if abs(g.contrast) >= 1 { parts.append(String(format: "%+.0f contrast", g.contrast)) }
        if abs(g.vibrance) >= 1 { parts.append(String(format: "%+.0f vibrance", g.vibrance)) }
        else if abs(g.saturation) >= 1 { parts.append(String(format: "%+.0f saturation", g.saturation)) }
        if parts.isEmpty, abs(g.highlights) >= 1 {
            parts.append(String(format: "%+.0f highlights", g.highlights))
        }
        return parts.isEmpty ? "as shot" : parts.prefix(3).joined(separator: " · ")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(nsImage: candidate.previewImage)
                    .resizable().scaledToFill()
                    .frame(width: 62, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))

                // THE MIDDLE COLUMN IS THE ONE THAT GIVES. A row is a 62 pt thumbnail, a name, a
                // line of numbers and a temperature — and in a 300 pt panel there is not room for
                // all of it at natural width. Without saying which part yields, SwiftUI shared the
                // shortfall out and pushed the temperature off the edge, so the panel looked cut in
                // half. The name and the numbers truncate; the temperature does not, because a
                // half-drawn "as-shot" is worse than a shortened signature.
                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.label)
                        .font(Theme.ui(14, .semibold))
                        .foregroundColor(isSelected ? Theme.ink : Theme.inkDim)
                        .lineLimit(1)
                    Text(signature)
                        .font(Theme.mono(10)).foregroundColor(Theme.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    Circle().fill(temp.map(KelvinScale.color) ?? Theme.inkFaint)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                    Text(temp.map { "\(Int($0))K" } ?? "as-shot")
                        .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .layoutPriority(1)
            }
            .padding(9)
            // The candidate rows are the one piece of content in the panel worth making of glass:
            // they are cards ABOUT photographs, sitting on chrome, and they are what the eye goes to
            // first. The selected one takes the rim light — the same warm-through-cool hairline the
            // header and footer carry — so "chosen" is said in the app's own physics rather than
            // with a second accent colour.
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.glassCard)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Theme.glow.opacity(0.10) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected
                                          ? AnyShapeStyle(Theme.rimLight)
                                          : AnyShapeStyle(Theme.hairline.opacity(0.5)),
                                          lineWidth: isSelected ? 1.5 : 1))
            }
        }
        .buttonStyle(.plain)
        // The row is a thumbnail plus two lines of numbers, so unlabelled it announces as an image
        // and a shrug. Spoken, it is the style, then what actually separates it from the others.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signature.isEmpty
                            ? "\(candidate.label), no adjustments"
                            : "\(candidate.label), \(signature)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // Picking a candidate is the one act this whole app is built around, and the selection
        // moves between rows — so the border and fill hand over rather than cutting. Colour and
        // stroke width only: no scale, no shadow, nothing that would make a row jump at the eye
        // while it is being compared against the photograph.
        .animation(Motion.gated(Motion.quick, reduceMotion), value: isSelected)
    }
}

// MARK: - Histogram (live tonal distribution + clipping)

/// The histogram as numbers. Lives outside `HistogramView` so that it carries no main-actor
/// isolation: it is computed on the render lane, beside the pixels it describes, and only drawn on
/// the main thread. (SwiftUI views are `@MainActor`, and so is everything nested in them; the
/// runtime flagged the first attempt that left this inside.)
/// What one pass over the sampled pixels yields. Plain numbers, so it can be computed on the
/// render lane beside the pixels it describes and published to the main thread as data.
struct HistogramReading: Sendable {
    var channels: [[Double]]          // R, G, B — 64 bins each
    var peak: Double                  // shared across channels, so casts stay visible
    var shadowClipped: [String]
    var highlightClipped: [String]
    /// The mean colour of the pixels in each luma bin, and how many there were. Zero weight
    /// means the photograph has nothing at that brightness.
    var signature: [(r: Double, g: Double, b: Double, weight: Double)]

    /// The signature as gradient stops.
    ///
    /// The colour is lifted toward full brightness before it is drawn. A mean shadow colour is
    /// by definition dark, and dark-on-near-black is invisible — so the strip shows each tone's
    /// *hue and saturation* at a legible lightness rather than its literal value, which the
    /// curves above already carry. Without this the left half of the strip is a black smear.
    var signatureStops: [Gradient.Stop] {
        signature.enumerated().map { i, t in
            let location = Double(i) / Double(max(1, signature.count - 1))
            guard t.weight > 0 else { return .init(color: .clear, location: location) }
            let peak = max(t.r, max(t.g, t.b))
            // Scale so the strongest channel lands at 0.92. NOT clamped to 1 — clamping is what
            // a first draft did, and since every shadow tone has a peak below 1 the "lift" could
            // then only ever darken, leaving the left half of the strip the black smear it was
            // written to prevent.
            //
            // But the gain is FLOORED AND CAPPED, because unbounded normalisation is its own
            // bug and it was visible on screen: a bin averaging almost-black has a peak around
            // 0.008, which asked for a seventy-eight-fold lift and turned 8-bit rounding noise
            // into a confident white band at the shadow end. Below the floor there is no hue
            // left in the data to show; above it the cap means very dark tones stay legibly
            // darker than midtones instead of every tone being normalised to one brightness.
            guard peak > 0.04 else {
                return .init(color: Color(white: 0.12), location: location)
            }
            let lift = min(0.92 / peak, 6)
            return .init(color: Color(red: min(1, t.r * lift),
                                      green: min(1, t.g * lift),
                                      blue: min(1, t.b * lift)),
                         location: location)
        }
    }

    /// Clipping in words. Colour and position say it first; this says it in a form that survives
    /// being colourblind, printed, or simply not looked at closely.
    var clippingSummary: String {
        var parts: [String] = []
        if !shadowClipped.isEmpty { parts.append("▼ \(shadowClipped.joined())") }
        if !highlightClipped.isEmpty { parts.append("▲ \(highlightClipped.joined())") }
        return parts.joined(separator: "  ")
    }

    var tooltip: String {
        guard !clippingSummary.isEmpty else {
            return "Tonal distribution by channel — where the three agree they read grey, "
                + "so colour here means a cast"
        }
        var out: [String] = []
        if !shadowClipped.isEmpty {
            out.append("\(shadowClipped.joined(separator: ", ")) crushed to pure black")
        }
        if !highlightClipped.isEmpty {
            out.append("\(highlightClipped.joined(separator: ", ")) blown to pure white")
        }
        return out.joined(separator: " · ") + " — detail is gone, not just dark or bright"
    }
}


/// The one pass that produces a `HistogramReading`. Same rule as the struct: no actor, any thread.
enum HistogramReader {
    /// Channel names, here rather than on the view: the view is `@MainActor` and this is not.
    static let channelNames = ["R", "G", "B"]
    /// Three 64-bin channel histograms plus exact clipping counts, from one pass over the sample.
    ///
    /// The comment here used to say "Cheap (100×100 sample)" and it was not: `rgba8Sampled`
    /// rasterises the image at its FULL extent and only then downsamples, so asking for 100×100
    /// rendered all 1200 px of the proxy first. That happened inside a `Canvas` draw closure — the
    /// main thread — on every render, which means on every tick of every slider drag.
    ///
    /// Scaling the CIImage down BEFORE the raster makes the claim true. Done here rather than in
    /// `rgba8Sampled` because a dozen measurement paths depend on that function's exact resampling,
    /// and this is a histogram: a few bins of difference are invisible, whereas silently moving
    /// `FaceSkin` or `SubjectMask` numbers is how a calibrated threshold stops meaning what it did.
    ///
    /// Three channels cost no more than the one this replaced: it is the same raster and the same
    /// single walk of the buffer, binning three values per pixel instead of computing one.
    static func read(_ image: CIImage?) -> HistogramReading? {
        guard let image else { return nil }
        let small = PerceptionProxy.downsample(image, maxEdge: 100)
        guard let data = try? ImageWriter.rgba8Sampled(small, width: 100, height: 100) else { return nil }

        var channels = [[Double]](repeating: [Double](repeating: 0, count: 64), count: 3)
        var atFloor = [0, 0, 0], atCeiling = [0, 0, 0]
        // Colour summed per LUMA bin — the tone-colour signature. Same walk, three more adds.
        var toneSum = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 64)
        var toneCount = [Double](repeating: 0, count: 64)
        var samples = 0
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) {
                samples += 1
                let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                let bin = min(63, Int(luma) >> 2)
                toneSum[bin][0] += r; toneSum[bin][1] += g; toneSum[bin][2] += b
                toneCount[bin] += 1
                for c in 0..<3 {
                    let v = px[i + c]
                    channels[c][Int(v) >> 2] += 1
                    // CLIPPING IS MEASURED ON THE RAW VALUE, not on the end bin. A 64-bin bin covers
                    // four levels, so "bin 63 is tall" also fires on a frame that merely has bright
                    // highlights with all their detail intact — which is how a clipping warning
                    // becomes something people learn to ignore.
                    if v == 0 { atFloor[c] += 1 }
                    if v == 255 { atCeiling[c] += 1 }
                }
            }
        }
        guard samples > 0 else { return nil }
        // A tenth of a percent of the frame. Below that it is a stray pixel or two — a specular
        // highlight on a chrome edge is not a blown photograph, and warning about it trains people
        // to stop reading the warning.
        let threshold = max(1, samples / 1000)
        let names = channelNames
        let peak = channels.flatMap { $0 }.max() ?? 0
        // A bin holding a handful of stray pixels is noise, not a tone the photograph has. Below
        // that floor it stays transparent rather than contributing a wild mean colour drawn from
        // three pixels.
        let toneFloor = max(1.0, Double(samples) / 2000)
        let signature = (0..<64).map { i -> (r: Double, g: Double, b: Double, weight: Double) in
            let n = toneCount[i]
            guard n >= toneFloor else { return (0, 0, 0, 0) }
            return (toneSum[i][0] / n / 255, toneSum[i][1] / n / 255, toneSum[i][2] / n / 255, n)
        }
        return HistogramReading(
            channels: channels,
            peak: peak,
            shadowClipped: (0..<3).filter { atFloor[$0] > threshold }.map { names[$0] },
            highlightClipped: (0..<3).filter { atCeiling[$0] > threshold }.map { names[$0] },
            signature: signature)
    }
}


/// The tonal readout: three channel curves, additively blended, over a quarter-stop grid.
///
/// **It used to be one grey silhouette of luma, and luma is the one thing a photographer can already
/// see by looking at the picture.** What it could not tell you is the part the eye is worst at —
/// which *channel* is doing it. A warm cast, a blue shadow, a red channel clipping on a face while
/// the frame's overall brightness looks perfectly healthy: all of that is invisible in a luma
/// silhouette and obvious the moment the channels are drawn apart.
///
/// **The blend is the whole trick.** The three curves composite additively, so where the channels
/// agree they sum back to neutral grey — which *is* the luma reading, for free, with no fourth
/// series drawn — and where they disagree the difference shows as colour. Neutral photograph, grey
/// histogram. Cast, and it fringes. Nothing here is decoration: every colour on screen is the data.
///
/// Drawn thin and lit rather than as three saturated blocks, because saturated fills at this size
/// read as a toy. Fills sit low and the strokes carry the shape.
struct HistogramView: View {
    typealias Reading = HistogramReading
    /// Computed off the main thread, where the pixels were rendered; this view only draws it.
    let reading: Reading?

    /// Channel colours, lifted off the primaries so they stay legible on a near-black surface while
    /// still summing to something that reads as neutral where all three overlap.
    private static let channelColors: [Color] = [
        Color(hex: 0xFF4D4D), Color(hex: 0x4DE07A), Color(hex: 0x4D95FF)
    ]
    private static var channelNames: [String] { HistogramReader.channelNames }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Canvas { ctx, size in
                // The grid first and underneath everything: solid hairlines one shade off the
                // surface, at the quarter stops. Not dashed — a dashed rule reads as a threshold
                // someone chose, and these are just somewhere to measure against.
                for q in 1..<4 {
                    let x = size.width * CGFloat(q) / 4
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0))
                                      $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(Theme.hairline.opacity(0.55)), lineWidth: 1)
                }
                guard let reading, reading.peak > 0 else { return }

                // ONE shared peak across all three channels, never a peak per channel. Normalising
                // each to its own maximum would flatten every cast in the shoot to the same shape —
                // the exact thing this view now exists to show.
                ctx.blendMode = .plusLighter
                for (i, bins) in reading.channels.enumerated() {
                    let color = Self.channelColors[i]
                    let curve = Self.curve(bins, peak: reading.peak, in: size)
                    var filled = curve
                    filled.addLine(to: CGPoint(x: size.width, y: size.height))
                    filled.addLine(to: CGPoint(x: 0, y: size.height))
                    filled.closeSubpath()
                    ctx.fill(filled, with: .linearGradient(
                        Gradient(colors: [color.opacity(0.42), color.opacity(0.06)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    // Two passes for the stroke: a wide soft one under a fine bright one. Under
                    // plusLighter that is a bloom, which is what a lit trace looks like — and it
                    // costs one extra stroke rather than a blur filter on every slider tick.
                    ctx.stroke(curve, with: .color(color.opacity(0.22)), lineWidth: 3.5)
                    ctx.stroke(curve, with: .color(color.opacity(0.95)), lineWidth: 1.2)
                }
                ctx.blendMode = .normal

                // Clipping is a STATUS, so it gets the status colour and never a channel's — with
                // three channels drawn, a blue "shadows clipped" bar would read as the blue channel.
                // A wedge in the corner the clipping happened in, and the caption says which
                // channels in words, so the mark is never the only thing carrying the message.
                if !reading.shadowClipped.isEmpty { Self.wedge(ctx, size: size, leading: true) }
                if !reading.highlightClipped.isEmpty { Self.wedge(ctx, size: size, leading: false) }
            }
            .frame(height: 58)

            // THE TONE-COLOUR SIGNATURE: the frame's average colour at each point of its tonal
            // range, from its blacks on the left to its whites on the right.
            //
            // This is the reading a colourist actually works in and no histogram shape can give
            // you: not "how much dark" but "what colour the dark IS". Cool shadows warming into
            // amber highlights is a split tone, and it shows up here as a gradient you can name in
            // one look — where in the curves above it is three lines being slightly apart.
            //
            // Bins with no pixels in them stay transparent, so the strip lights up across exactly
            // the range the photograph occupies and goes dark where it has nothing. An empty gap is
            // a fact about the frame, not a hole in the drawing.
            if let reading, reading.peak > 0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(stops: reading.signatureStops,
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 7)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.hairline.opacity(0.6),
                                                                     lineWidth: 0.5))
            }

            // The legend, always present because there are three series — and lettered, so identity
            // never rests on colour alone.
            HStack(spacing: 7) {
                ForEach(Array(Self.channelNames.enumerated()), id: \.offset) { i, name in
                    Text(name)
                        .font(Theme.mono(9, .semibold))
                        .foregroundColor(Self.channelColors[i].opacity(0.9))
                }
                Spacer(minLength: 4)
                if let reading, !reading.clippingSummary.isEmpty {
                    Text(reading.clippingSummary)
                        .font(Theme.mono(9))
                        .foregroundColor(Theme.warn)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        // A shallow top-down gradient rather than flat black: the curves are lit marks, and a
        // surface with a little depth under them reads as an instrument rather than a swatch.
        // Kept very close to the panel's own colour — this is depth, not a second accent.
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(LinearGradient(colors: [Color.black.opacity(0.46), Color.black.opacity(0.26)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1)))
        .help(reading?.tooltip ?? "The tonal distribution of the rendered photo, by colour channel")
        // A HISTOGRAM IS PURE GEOMETRY, so a label naming it says nothing — "histogram" tells a
        // VoiceOver user exactly as much as an unlabelled image does. What it has to speak is the
        // reading itself: where the tones sit, whether there is a cast, and what is clipping.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(reading))
    }

    /// The histogram in words.
    ///
    /// Describes the same three things the drawing does, in the same order: where the mass of the
    /// tones is, whether the channels disagree (which is what colour in the curves means), and what
    /// is clipped. Derived from the bins rather than restating the picture, so it cannot drift away
    /// from what is on screen.
    static func spoken(_ reading: Reading?) -> String {
        guard let reading, reading.peak > 0 else { return "Tonal readout, no photograph loaded" }
        let luma = (0..<64).map { i in reading.channels.reduce(0) { $0 + $1[i] } }
        let total = luma.reduce(0, +)
        guard total > 0 else { return "Tonal readout, nothing measurable" }
        // Thirds. Finer than that is precision nobody can act on by ear.
        let shadows = luma[0..<21].reduce(0, +) / total
        let mids = luma[21..<43].reduce(0, +) / total
        let highs = luma[43..<64].reduce(0, +) / total
        let heaviest = max(shadows, max(mids, highs))
        let placement = heaviest == shadows ? "mostly in the shadows"
            : heaviest == highs ? "mostly in the highlights" : "mostly in the midtones"

        var parts = ["Tonal readout, " + placement]
        // A cast, said as the channels-disagree fact the drawing shows as colour.
        let means = reading.channels.map { bins in
            bins.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element } / total * 3
        }
        if let hi = means.indices.max(by: { means[$0] < means[$1] }),
           let lo = means.indices.min(by: { means[$0] < means[$1] }),
           means[hi] - means[lo] > 2.5 {
            parts.append("\(channelNames[hi]) running brighter than \(channelNames[lo])")
        } else {
            parts.append("channels balanced")
        }
        if !reading.shadowClipped.isEmpty {
            parts.append(reading.shadowClipped.joined(separator: ", ") + " crushed to black")
        }
        if !reading.highlightClipped.isEmpty {
            parts.append(reading.highlightClipped.joined(separator: ", ") + " blown to white")
        }
        if reading.shadowClipped.isEmpty && reading.highlightClipped.isEmpty {
            parts.append("nothing clipped")
        }
        return parts.joined(separator: ", ")
    }

    /// A small right-angled wedge in the top corner of the end that is clipping.
    private static func wedge(_ ctx: GraphicsContext, size: CGSize, leading: Bool) {
        let s: CGFloat = 8
        let x0 = leading ? 0 : size.width
        let dir: CGFloat = leading ? 1 : -1
        var p = Path()
        p.move(to: CGPoint(x: x0, y: 0))
        p.addLine(to: CGPoint(x: x0 + s * dir, y: 0))
        p.addLine(to: CGPoint(x: x0, y: s))
        p.closeSubpath()
        ctx.fill(p, with: .color(Theme.warn))
    }

    /// The drawn shape for one channel: a smoothed open curve across the top of the bins.
    ///
    /// Smoothed for DRAWING ONLY. A 64-bin estimate off a 100×100 sample is visibly jagged, and the
    /// jaggedness is sampling noise rather than anything about the photograph. Clipping is detected
    /// from the raw 8-bit values instead (see `read`), so nothing that matters is smoothed away —
    /// which would be the one unforgivable version of this, a spike at pure white rounded off into
    /// a comfortable slope.
    private static func curve(_ bins: [Double], peak: Double, in size: CGSize) -> Path {
        let n = bins.count
        var path = Path()
        for i in 0..<n {
            let a = bins[max(0, i - 1)], b = bins[i], c = bins[min(n - 1, i + 1)]
            let v = (a + 2 * b + c) / 4
            let x = size.width * CGFloat(i) / CGFloat(n - 1)
            let y = size.height * (1 - CGFloat(min(1, v / peak * 1.05)))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

}

// MARK: - Tone slider (instrument readout)

/// What a control *does*, said in colour and light. Every slider used to be the same orange track,
/// so Temp and Contrast were the same object with different words on top; the rail under the knob
/// makes the action legible before the label is read.
///
/// The identity describes the ACTION, never the value — the value stays in the knob position and
/// the monospaced readout, so nothing here is the only way to read the control.
/// Equatable so `ToneSlider` can be skipped when nothing about it changed — see the wrapper there.
enum ToneIdentity: Equatable {
    /// Geometry, softness, feather: no honest reading in light. Left exactly as it was — a rail
    /// that says nothing is decoration, and decoration in a darkroom panel costs attention the
    /// photograph should be getting.
    case plain
    case temperature
    case tint
    case exposure
    case contrast
    /// Highlights and Shadows both brighten to the right, as the knob does. What separates them is
    /// which end of the scale they work in, so that — not direction — is what the rails show.
    case highlights
    case shadows
    /// Chroma rising left to right. `hue` nil means every hue at once, i.e. the global pair.
    case saturation(hue: Double?)
    /// The mixer rotating one band: the rail is that band and the neighbours it can reach.
    case hueShift(center: Double)
    /// The whole hue circle as a selection axis (the colour-range mask picks a point on it).
    case spectrum
    /// Haze → definition. The quietest of the family on purpose: clarity and texture are small
    /// effects, and a loud rail would oversell them.
    case presence

    /// Hue angles for the mixer's eight bands. Deliberately not derived from `bandColor` — that
    /// vends system colours for the swatches, and a rail has to interpolate toward a band's
    /// neighbours, which needs an angle rather than a swatch.
    static func bandHue(_ band: String) -> Double {
        switch band {
        case "red":    return 0
        case "orange": return 30
        case "yellow": return 55
        case "green":  return 120
        case "aqua":   return 185
        case "blue":   return 225
        case "purple": return 280
        default:       return 320   // magenta
        }
    }

    /// The mask panel builds its sliders from `maskAdjustmentSpecs`, so it identifies them by key
    /// rather than at the call site.
    static func adjustment(_ key: String) -> ToneIdentity {
        switch key {
        case "exposure_ev":            return .exposure
        case "highlights":             return .highlights
        case "shadows":                return .shadows
        case "contrast":               return .contrast
        case "saturation", "vibrance": return .saturation(hue: nil)
        default:                       return .plain
        }
    }
}

/// The axis a slider's knob travels along, drawn as light.
///
/// It sits below the native track rather than behind it, for two reasons: the knob keeps its own
/// contrast against the system track no matter how dark the rail gets, and the gradient reads as a
/// scale the knob moves along instead of as a second value indicator. Everything is muted to
/// roughly the temperature rail's weight — the sidebar sits next to a photograph and must not
/// compete with it.
struct ToneRail: View {
    let identity: ToneIdentity

    private static let thickness: CGFloat = 4

    // A quiet, slightly desaturated palette: full-strength hues next to a near-black panel read as
    // toy UI, and the greys need more alpha than the colours to register at all.
    private static let greenTint   = Color(hex: 0x6FB98A)
    private static let neutralTint = Color(hex: 0xB6BCC5)
    private static let magentaTint = Color(hex: 0xC182B4)
    private static let ashDark     = Color(hex: 0x1C1F26)
    private static let ashMid      = Color(hex: 0x707783)
    private static let ashLight    = Color(hex: 0xE6E9EE)
    private static let flatGrey    = Color(hex: 0x7A8089)

    var body: some View {
        switch identity {
        case .plain:
            EmptyView()

        // The app's own Kelvin scale, oriented as the signature rail orients it: low K (amber) at
        // the left, high K (blue) at the right. Reusing it keeps one colour-temperature ramp in
        // the product rather than two that drift apart.
        case .temperature:
            bar(KelvinScale.gradient, opacity: 0.55)

        case .tint:
            bar(gradient([Self.greenTint, Self.neutralTint, Self.magentaTint]), opacity: 0.5)

        case .exposure:
            bar(gradient([Self.ashDark, Self.ashMid, Self.ashLight]), opacity: 0.7)

        // Contrast is the one control whose action is a *spread*, so the rail splits: flat and
        // identical at the left, opening toward black and white as the knob moves right.
        case .contrast:
            VStack(spacing: 1) {
                halfBar([Self.flatGrey, Color(hex: 0xA8AFB9), Color(hex: 0xF3F5F8)])
                halfBar([Self.flatGrey, Color(hex: 0x555B65), Color(hex: 0x0E1014)])
            }
            .accessibilityHidden(true)

        case .highlights:
            bar(gradient([Color(hex: 0x5C626C), Color(hex: 0xA9B0BA), Color(hex: 0xF1F3F6)]), opacity: 0.7)

        case .shadows:
            bar(gradient([Color(hex: 0x171A20), Color(hex: 0x4A5058), Color(hex: 0x9AA1AB)]), opacity: 0.7)

        // Constant brightness, rising chroma: grey at the left, colour at the right, which is the
        // whole of what the control does. Brightness is held flat on purpose so it cannot be
        // mistaken for one of the tonal rails.
        case .saturation(let hue):
            bar(Self.chromaRamp(hue: hue), opacity: 0.6)

        case .hueShift(let center):
            bar(gradient([Self.muted(center - 55), Self.muted(center), Self.muted(center + 55)]), opacity: 0.5)

        case .spectrum:
            bar(Self.spectrum, opacity: 0.45)

        // Stops bunched to the right: flat and hazy across most of the travel, separating only as
        // the effect starts to bite. Cool and stopping short of white, so it reads as atmosphere
        // clearing rather than as one more brightness ramp.
        case .presence:
            bar(LinearGradient(stops: [
                .init(color: Color(hex: 0x36404E), location: 0),
                .init(color: Color(hex: 0x414C5B), location: 0.55),
                .init(color: Color(hex: 0xA3B2C4), location: 1)
            ], startPoint: .leading, endPoint: .trailing), opacity: 0.6)
        }
    }

    private func bar(_ fill: some ShapeStyle, opacity: Double) -> some View {
        Capsule().fill(fill)
            .frame(height: Self.thickness)
            .opacity(opacity)
            .accessibilityHidden(true)
    }

    private func halfBar(_ colors: [Color]) -> some View {
        Capsule().fill(gradient(colors))
            .frame(height: (Self.thickness - 1) / 2)
            .opacity(0.85)
    }

    private func gradient(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    /// A hue at instrument strength rather than screen-primary strength.
    private static func muted(_ degrees: Double) -> Color {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return Color(hue: (wrapped < 0 ? wrapped + 360 : wrapped) / 360, saturation: 0.58, brightness: 0.88)
    }

    private static let spectrum = LinearGradient(
        colors: stride(from: 0.0, through: 360.0, by: 60.0).map { muted($0) },
        startPoint: .leading, endPoint: .trailing)

    /// Grey → colour at a fixed brightness. `hue` nil walks the whole circle, which is what the
    /// global pair actually touches; a single hue is the mixer working on one band.
    private static func chromaRamp(hue: Double?) -> LinearGradient {
        let stops = (0...8).map { i -> Color in
            let t = Double(i) / 8
            return Color(hue: hue.map { $0 / 360 } ?? t, saturation: 0.62 * t, brightness: 0.74)
        }
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }
}

/// A labelled slider.
///
/// DO NOT REACH FOR `.equatable()` HERE. It was tried, measured and removed. The theory was sound —
/// SwiftUI cannot tell whether a `Binding` changed, so dragging Exposure re-evaluates all fourteen
/// tone sliders and their rails — but wrapping the row in an `EquatableView` changed nothing, and an
/// `==` hard-coded to return `true` changed nothing either: 12,000 body evaluations across a
/// 120-step drag, with and without. SwiftUI declines the optimisation for a view holding dynamic
/// properties, and this one holds `@State`, `@Binding` and `@Environment`.
///
/// What the panel actually costs is laying out ~53 of these per displayed frame, and the only fix
/// that reaches it is finer-grained observation — `AppState` publishing 71 properties into one
/// 1300-line body — which is a refactor rather than a wrapper. See the profiling notes in
/// Diagnostics.swift.
struct ToneSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let onChange: () -> Void
    /// Defaults to `.plain` so a control only claims a meaning when someone decided it has one.
    var identity: ToneIdentity = .plain
    /// Bumped by the double-click reset, and the ONLY thing the readout animates on.
    ///
    /// The obvious move — animating `value` back to neutral — is not available: `value` is bound
    /// straight to the render, so easing it would push a stream of intermediate recipes through
    /// the pipeline and put intermediate states into the undo history. The number therefore snaps,
    /// as does the knob, and only the readout's colour acknowledges the reset. Keying on a counter
    /// rather than on `value` also guarantees this can never fire mid-drag.
    /// Called with true when a drag starts and false when it ends. Used to hide the mask overlay
    /// for the duration, so the photograph is visible while it is being judged.
    var onDragging: (Bool) -> Void = { _ in }
    /// Where double-click sends this control. Defaults to zero for the signed ±100 scales, and is
    /// given explicitly by the ones whose neutral is elsewhere.
    var neutral: Double = 0
    @State private var resetTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The value, snapped to `step` on the way in. See the Slider below for why the stepping cannot
    /// live where it looks like it belongs.
    private var steppedValue: Binding<Double> {
        Binding(get: { value },
                set: { raw in
                    let snapped = (raw / step).rounded() * step
                    value = min(max(snapped, range.lowerBound), range.upperBound)
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(Theme.ui(12)).foregroundColor(Theme.inkDim)
                Spacer()
                Text(readout)
                    .font(Theme.mono(11, value == neutral ? .regular : .semibold))
                    .foregroundColor(value == neutral ? Theme.inkFaint : Theme.glow)
                    .animation(Motion.gated(Motion.quick, reduceMotion), value: resetTick)
            }
            VStack(spacing: 3) {
                // `onEditingChanged` brackets the DRAG — true when the thumb is grabbed, false
                // when it is let go. The overlay-suppression flag was being driven from the value
                // setter and `onChange` instead, which meant it went true, then false, and only
                // THEN was a render built: never true when it was read, so the feature was dead on
                // arrival. A gesture's begin and end are the only honest place to bracket a
                // gesture.
                // STEPPED IN THE BINDING, NOT IN THE SLIDER. This is the edit-panel stutter, and it
                // was never Kelvin's own code: `Slider(value:in:step:)` becomes an `NSSlider` with
                // ONE TICK MARK PER STEP — 701 of them for Temp (2500…9500 by 10), 301 for
                // Straighten, 201 for Exposure. Laying one out runs
                // `_rebuildTickMarkRectCache` → `rectOfTickMarkAtIndex:` → `_visualProvider` →
                // `setUsesModernStyle:` → `_rebuildTickMarkRectCache`, re-entering itself per tick,
                // thousands of frames deep. A 600-step automated drag on a 61 MB ARW spent 83% of
                // the main thread inside that recursion and took 349 s instead of 10.
                //
                // Snapping in the binding keeps the behaviour — values still land on the step, and
                // a sub-step drag now produces no change and therefore no render — while the
                // control AppKit builds has no tick marks to lay out.
                Slider(value: steppedValue, in: range, onEditingChanged: onDragging)
                    // The accent stays the same on every slider: it is the language of "where the
                    // value is", and the rail below is the language of "what this does". Making
                    // both vary at once would leave neither reliable.
                    .tint(Theme.glow)
                    .controlSize(.small)
                    // Live: re-render on every value change during the drag, not just on release.
                    .onChange(of: value) { onChange() }
                ToneRail(identity: identity)
            }
        }
        // Double-click the row to reset this control to its neutral value.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Reset to this control's OWN neutral, not to literal zero. Guarding on
            // `range.contains(0)` made the gesture silently dead on every slider whose scale does
            // not straddle zero — Temp (2500…9500), radial Size, Brush size, Skin tolerance and
            // the three 0.01…0.5 Range sliders. Seven controls where double-click did nothing and
            // nothing said why.
            value = neutral
            onChange()
            resetTick += 1
        }
    }

    private var readout: String {
        let sign = value > 0 ? "+" : ""
        return step < 1
            ? String(format: "%@%.2f%@", sign, value, unit)
            : String(format: "%@%.0f%@", sign, value, unit)
    }
}

// MARK: - Hand-drawn gradient mask (view-model + editor)

/// A hand-added parametric mask — a radial/linear gradient or a brushed region — all plain values
/// so SwiftUI binds to it directly. Converts to the engine's `Mask` at render time.
/// A snapshot of the full manual-edit state, for undo/redo.
struct EditSnapshot: Equatable {
    var edit: GlobalAdjustments
    var userMasks: [UserMaskVM]
    var maskEnabled: [String: Bool]
    var maskStrength: [String: Double]
    var straighten: Double
    var hsl: [String: HSLAdjustment]
    /// Heals ride in the undo history like every other edit — ⌘Z after a click removes that spot.
    var healSpots: [HealSpot]
}

struct UserMaskVM: Identifiable, Equatable, Codable {
    /// `CaseIterable` so the contract tests can enumerate every kind instead of keeping their own
    /// hand-written list of them. There were three such lists — `UserMaskTests.allKinds`,
    /// `AppStateTests`' new-mask sweep, `MaskPresetTests`' capturable sweep — and a kind added
    /// without being pasted into all three is not a failing test, it is a kind that silently has no
    /// coverage. Same rule as `Mask.adjustmentKeys`: two hand-written lists cannot disagree if there
    /// is only one list.
    enum Kind: String, Codable, CaseIterable {
        case radial, linear, brush, colorRange, luminance, skin, background, subject, instance, sky
        /// The magic wand — a region grown outward from one clicked point. The contiguous
        /// counterpart to `colorRange`: that takes every matching pixel in the frame, this takes
        /// the one connected thing you pointed at.
        case wand
    }
    var id = UUID()
    var kind: Kind
    var cx = 0.5, cy = 0.5, radius = 0.35, angle = 0.0, softness = 0.35
    var stamps: [BrushStamp] = []                       // brush only
    var selCenter = 0.0, selRange = 0.1, selSoftness = 0.1   // colour / luminance / skin selection
    /// Wand only: how far the fill may spread from the seed, and how softly it stops. The seed
    /// itself is `cx`/`cy` — it is a point on the picture, which is exactly what those already mean
    /// for a radial mask, and inventing a second pair of coordinates for the same idea is how two
    /// fields that must agree end up disagreeing.
    var wandTolerance = 0.10, wandSoftness = 0.25
    /// The local adjustments this mask carries. Keys and ranges live in
    /// `AppState.maskAdjustmentSpecs`, and the editor builds its sliders from that list, so a
    /// hand-drawn mask and an auto mask can never again offer different controls.
    ///
    /// It used to be exposure/contrast/saturation and nothing else, while the renderer honoured
    /// six — so `shadows`, `highlights` and `vibrance` were unreachable on every mask a user
    /// drew: radial, graduated, brush, colour, luminance, skin, background, subject, instance.
    /// All nine. The two auto masks got the full set. The sharpest version of the gap is that
    /// `RecipeEngine.subjectMask` reaches for `shadows` deliberately — "detail recovery weighted
    /// over raw exposure, kinder to skin at any tone" — and someone painting a mask over that
    /// same face could not.
    ///
    /// Optional-with-default so a sidecar written before these existed still decodes.
    var exposure = 0.0, contrast = 0.0, saturation = 0.0
    var shadows = 0.0, highlights = 0.0, vibrance = 0.0
    var tightness = 0.0
    var feather = 0.0
    var invert = false
    /// `.instance` only: which detected subject this mask is for. The renderer looks the bitmap up
    /// under this id, and the export path matches it back to a fresh full-resolution detection —
    /// see `SubjectInstances.reidentify`, because the id is a per-pass index and means nothing on
    /// its own. Optional (and absent from older sidecars) so decoding an edit saved before
    /// per-subject masks existed still works.
    var instanceId: String?
    /// The label as it was when the mask was made ("Person 2", "Cat"). Stored rather than looked
    /// up so an edit reopened after a detection that came back slightly differently still says
    /// what the photographer thought they were editing.
    var instanceLabel: String?
    /// WHERE the subject was, normalised, when the mask was made — the part of its identity that
    /// survives a sidecar. The id does not: reopen the photo and the segmentation runs again with
    /// fresh per-pass indices, so a saved mask keyed only by id comes back pointing at nobody. The
    /// box is what `rekeyInstanceMasks` matches on to find the same subject again.
    var instanceBox: CGRect?
    /// Kind at the time, for the same reason — it tie-breaks the match.
    var instanceKind: SubjectInstances.Kind?
    /// What the photographer calls this mask. Nil falls back to the kind's name, which is how it
    /// was: three radial masks were all called "Radial", in a list, with nothing to tell them
    /// apart. Fine with one mask and useless with four.
    var name: String?
    /// THE UNIVERSAL MODIFIER. Narrows whatever region this mask defines to pixels that also fall
    /// in a colour or luminance range — "the skin within this person", "the highlights inside this
    /// graduated filter", "the reds in the bottom half".
    ///
    /// `.skin` used to be the only mask that could do this, because the intersection was written
    /// into the renderer as a special case for one type. It is available on every mask now, which
    /// is the whole point of collapsing the kinds into one primitive.
    enum Refinement: String, Codable, CaseIterable { case none, colour, luminance }
    var refinement: Refinement = .none
    var refineCenter = 0.06, refineRange = 0.12, refineSoftness = 0.06

    /// The subject this mask is bound to, when it is bound to one — `.instance` always, `.skin`
    /// when scoped to a single person. Every site that re-identifies subjects (export at full
    /// resolution, re-keying after a fresh detection) must use THIS rather than testing the kind,
    /// so a new instance-bound kind cannot be silently left out of re-identification again.
    var boundInstanceId: String? {
        (kind == .instance || kind == .skin) ? instanceId : nil
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, cx, cy, radius, angle, softness, stamps, selCenter, selRange, selSoftness
        case exposure, contrast, saturation, instanceId, instanceLabel, instanceBox, instanceKind
        case tightness, feather, invert
        // EVERY STORED PROPERTY MUST BE LISTED HERE. With an explicit `CodingKeys`, the synthesised
        // encoder writes only what this enum names — so a property added above and forgotten here
        // is not a smaller file, it is silent data loss. `init(from:)` decodes these with
        // defaults, which is exactly what made it invisible: the values came back looking like
        // untouched defaults rather than like something that failed to save.
        //
        // Lost this way until now: the three adjustments hand-drawn masks had just gained
        // (shadows, highlights, vibrance), every mask's name, and the whole refine feature. All of
        // it survived switching photos, because that path keeps objects in memory, and vanished on
        // relaunch.
        case shadows, highlights, vibrance, name
        case refinement, refineCenter, refineRange, refineSoftness
        case wandTolerance, wandSoftness
    }

    init(id: UUID = UUID(), kind: Kind, cx: Double = 0.5, cy: Double = 0.5, radius: Double = 0.35, angle: Double = 0.0, softness: Double = 0.35, stamps: [BrushStamp] = [], selCenter: Double = 0.0, selRange: Double = 0.1, selSoftness: Double = 0.1, exposure: Double = 0.0, contrast: Double = 0.0, saturation: Double = 0.0, instanceId: String? = nil, instanceLabel: String? = nil, instanceBox: CGRect? = nil, instanceKind: SubjectInstances.Kind? = nil, tightness: Double = 0.0, feather: Double = 0.0, invert: Bool = false) {
        self.id = id; self.kind = kind; self.cx = cx; self.cy = cy; self.radius = radius; self.angle = angle; self.softness = softness
        self.stamps = stamps; self.selCenter = selCenter; self.selRange = selRange; self.selSoftness = selSoftness
        self.exposure = exposure; self.contrast = contrast; self.saturation = saturation
        self.instanceId = instanceId; self.instanceLabel = instanceLabel; self.instanceBox = instanceBox; self.instanceKind = instanceKind
        self.tightness = tightness; self.feather = feather; self.invert = invert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        cx = try c.decodeIfPresent(Double.self, forKey: .cx) ?? 0.5
        cy = try c.decodeIfPresent(Double.self, forKey: .cy) ?? 0.5
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.35
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0.0
        softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? 0.35
        stamps = try c.decodeIfPresent([BrushStamp].self, forKey: .stamps) ?? []
        selCenter = try c.decodeIfPresent(Double.self, forKey: .selCenter) ?? 0.0
        selRange = try c.decodeIfPresent(Double.self, forKey: .selRange) ?? 0.1
        selSoftness = try c.decodeIfPresent(Double.self, forKey: .selSoftness) ?? 0.1
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0.0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0.0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0.0
        instanceId = try c.decodeIfPresent(String.self, forKey: .instanceId)
        instanceLabel = try c.decodeIfPresent(String.self, forKey: .instanceLabel)
        instanceBox = try c.decodeIfPresent(CGRect.self, forKey: .instanceBox)
        instanceKind = try c.decodeIfPresent(SubjectInstances.Kind.self, forKey: .instanceKind)
        tightness = try c.decodeIfPresent(Double.self, forKey: .tightness) ?? 0.0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.0
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        // The decoder is HAND-WRITTEN, so adding a key to `CodingKeys` fixes encoding and leaves
        // decoding still ignoring it — the file grows the field and nothing reads it back. Both
        // halves or neither.
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0.0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0.0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0.0
        name = try c.decodeIfPresent(String.self, forKey: .name)
        refinement = try c.decodeIfPresent(Refinement.self, forKey: .refinement) ?? .none
        refineCenter = try c.decodeIfPresent(Double.self, forKey: .refineCenter) ?? 0.06
        refineRange = try c.decodeIfPresent(Double.self, forKey: .refineRange) ?? 0.12
        refineSoftness = try c.decodeIfPresent(Double.self, forKey: .refineSoftness) ?? 0.06
        wandTolerance = try c.decodeIfPresent(Double.self, forKey: .wandTolerance) ?? 0.10
        wandSoftness = try c.decodeIfPresent(Double.self, forKey: .wandSoftness) ?? 0.25
    }

    var label: String {
        switch kind {
        case .radial: return "Radial"; case .linear: return "Graduated"; case .brush: return "Brush"
        case .colorRange: return "Colour range"; case .luminance: return "Luminance"; case .skin: return "Skin"
        case .background: return "Background"; case .sky: return "Sky"; case .wand: return "Wand"
        case .subject: return "Subject"
        case .instance: return instanceLabel ?? "Subject"
        }
    }

    /// The name shown in the panel: what it was renamed to, or what kind it is.
    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? label : trimmed
    }
    var hasCanvasHandles: Bool { kind == .radial || kind == .linear }

    /// Adjustments addressed by the same key the renderer and `maskAdjustmentSpecs` use, so the
    /// editor can be built from that list rather than from a hand-written set of sliders that
    /// silently fell behind it.
    subscript(adjustment key: String) -> Double {
        get {
            switch key {
            case "exposure_ev": return exposure
            case "contrast":    return contrast
            case "saturation":  return saturation
            case "shadows":     return shadows
            case "highlights":  return highlights
            case "vibrance":    return vibrance
            default:            return 0
            }
        }
        set {
            switch key {
            case "exposure_ev": exposure = newValue
            case "contrast":    contrast = newValue
            case "saturation":  saturation = newValue
            case "shadows":     shadows = newValue
            case "highlights":  highlights = newValue
            case "vibrance":    vibrance = newValue
            default:            break
            }
        }
    }

    func toMask() -> Mask {
        var adj: [String: Double] = [:]
        if exposure != 0 { adj["exposure_ev"] = exposure }
        if contrast != 0 { adj["contrast"] = contrast }
        if saturation != 0 { adj["saturation"] = saturation }
        if shadows != 0 { adj["shadows"] = shadows }
        if highlights != 0 { adj["highlights"] = highlights }
        if vibrance != 0 { adj["vibrance"] = vibrance }
        let f = feather
        let t = tightness
        let inv = invert
        // Applied to whatever region the source below produces. `.skin` still constructs its own
        // refinement from the legacy fields, so an existing skin mask is untouched by this.
        let ref: MaskSelection? = {
            switch refinement {
            case .none: return nil
            case .colour: return MaskSelection(kind: .color, center: refineCenter,
                                               range: refineRange, softness: refineSoftness)
            case .luminance: return MaskSelection(kind: .luminance, center: refineCenter,
                                                  range: refineRange, softness: refineSoftness)
            }
        }()
        switch kind {
        case .brush:
            return Mask(id: id.uuidString, type: "brush", source: "brush", invert: inv,
                        feather: f, opacity: 1, adjustments: adj, stamps: stamps, tightness: t,
                        refine: ref)
        case .radial, .linear:
            let sk: MaskShape.Kind = kind == .radial ? .radial : .linear
            return Mask(id: id.uuidString, type: sk.rawValue, source: "gradient", invert: inv,
                        feather: f, opacity: 1, adjustments: adj,
                        shape: MaskShape(kind: sk, cx: cx, cy: cy, radius: radius, angle: angle, softness: softness), tightness: t,
                        refine: ref)
        case .colorRange, .luminance:
            let k: MaskSelection.Kind = kind == .colorRange ? .color : .luminance
            return Mask(id: id.uuidString, type: k.rawValue, source: "selection", invert: inv,
                        feather: f, opacity: 1, adjustments: adj,
                        selection: MaskSelection(kind: k, center: selCenter, range: selRange, softness: selSoftness), tightness: t,
                        refine: ref)
        case .skin:
            // NOT a kind any more — a region narrowed to skin hues. Identical pixels to the old
            // bespoke path; it is just said in the general vocabulary now.
            //
            // `ref` wins when the user has set one. The editor shows the REFINE picker on every
            // kind, and this case used to ignore it and build a colour selection from the legacy
            // skin fields regardless — so choosing "Light" on a skin mask silently gave you a
            // colour narrowing instead. Worse than a dead control: the picture changed, just not
            // in the way that was asked for.
            let skinRef = ref ?? MaskSelection(kind: .color, center: selCenter,
                                               range: selRange, softness: selSoftness)
            if let inst = instanceId {
                // ONE person's skin: that subject's region, narrowed the same way. The mask's id
                // IS the instance id — the same contract as `.instance`, which is how the
                // renderer finds the bitmap and how export re-identifies the person at full
                // resolution. On a frame with three people, brightening the bride's skin must
                // not also brighten the groom's.
                return Mask(id: inst, type: "instance", source: "segmentation", invert: inv,
                            feather: f != 0 ? f : 30, opacity: 1, adjustments: adj, tightness: t,
                            refine: skinRef)
            }
            return Mask(id: id.uuidString, type: "subject", source: "segmentation", invert: inv,
                        feather: f, opacity: 1, adjustments: adj, tightness: t, refine: skinRef)
        case .background:
            // Also not a kind: the subject region, inverted. `invert` was always the modifier
            // doing the work — this case existed only to set it for you.
            let finalInvert = inv ? false : true
            let finalFeather = f != 0 ? f : 20
            return Mask(id: id.uuidString, type: "subject", source: "segmentation", invert: finalInvert,
                        feather: finalFeather, opacity: 1, adjustments: adj, tightness: t,
                        refine: ref)
        case .subject:
            let finalFeather = f != 0 ? f : 30
            return Mask(id: id.uuidString, type: "subject", source: "segmentation", invert: inv,
                        feather: finalFeather, opacity: 1, adjustments: adj, tightness: t,
                        refine: ref)
        case .instance:
            let finalFeather = f != 0 ? f : 30
            return Mask(id: instanceId ?? id.uuidString, type: "instance", source: "segmentation",
                        invert: inv, feather: finalFeather, opacity: 1, adjustments: adj, tightness: t,
                        refine: ref)
        case .sky:
            // The renderer already speaks "sky" — the engine's own sky treatment uses the same
            // segmentation bitmap under the same type key. This kind just puts that region in the
            // photographer's hands, which is what makes a "Stormy sky" preset a plain mask.
            return Mask(id: id.uuidString, type: "sky", source: "segmentation", invert: inv,
                        feather: f != 0 ? f : 20, opacity: 1, adjustments: adj, tightness: t,
                        refine: ref)
        case .wand:
            // A SEED, and the renderer regrows the pixels at whatever size it is working at. The
            // click lives in `cx`/`cy`, the same fields a radial mask uses for the same idea.
            //
            // A modest default feather: the fill already ramps its own edge across the tolerance,
            // so this is the ordinary mask softening on top of it rather than the fix for a hard
            // boundary. Too much here and a wand traced tightly round a rock reads as a glow.
            return Mask(id: id.uuidString, type: "wand", source: "region-grow", invert: inv,
                        feather: f != 0 ? f : 8, opacity: 1, adjustments: adj, tightness: t,
                        refine: ref,
                        region: RegionSeed(x: cx, y: cy,
                                           tolerance: wandTolerance, softness: wandSoftness))
        }
    }
}

struct UserMaskEditor: View {
    @Binding var mask: UserMaskVM
    let onChange: () -> Void
    let onDelete: () -> Void
    var isSelected = false
    var onSelect: () -> Void = {}
    /// Select-or-deselect, for the eye in the header. Separate from `onSelect` on purpose: the card
    /// tap must only ever select, so that clicking around inside a card cannot put its selection
    /// down by accident.
    var onToggleSelected: () -> Void = {}
    var isPainting = false
    var togglePaint: () -> Void = {}
    var clearStrokes: () -> Void = {}
    var brushRadius: Binding<Double> = .constant(0.09)
    /// Whether the brush takes coverage away rather than adding it. Bound rather than a flag on the
    /// mask: it is a mode on the tool, and it persists across strokes because erasing a spill off a
    /// mask takes several passes.
    var brushMode: Binding<Bool> = .constant(false)
    /// The wand's equivalent of `isPainting`/`togglePaint`: whether the canvas is waiting for this
    /// mask's seed click. A mode rather than an always-live click, for the same reason the subject
    /// pick is one — the canvas is also how you pan and zoom.
    var isSeeding = false
    var toggleSeeding: () -> Void = {}
    var hasPerson = true
    /// Whether that subject is actually a person. Drives the copy on the Subject and Skin cards,
    /// which otherwise promise a person over a mask that may be a dog or a sea stack.
    var subjectIsPerson = true
    /// The detected sky, for the same class of warning as `hasPerson`: a sky mask on a frame
    /// with no sky found is quietly inert, and quiet inertness is this session's most-reported
    /// bug shape.
    var hasSky = true
    /// The detected people on this frame, for the skin mask's "whose skin" choice. Empty means
    /// no choice to offer.
    var people: [SubjectInstances.Instance] = []
    /// Save these settings as a preset — wired by the owner of the mask list.
    var onSavePreset: () -> Void = {}
    /// Bracket a tone drag so the overlay steps aside while the photograph is being judged —
    /// otherwise you are grading 60% red and the slider appears to do nothing useful.
    var onAdjustBegin: () -> Void = {}
    var onAdjustEnd: () -> Void = {}
    var canMoveUp = false
    var canMoveDown = false
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}

    /// Skin and Background are built from the person segmentation — flag it when there isn't one,
    /// so the mask isn't just quietly inert.
    private var needsPersonButHasNone: Bool {
        (mask.kind == .skin || mask.kind == .background || mask.kind == .subject) && !hasPerson
    }

    private var needsSkyButHasNone: Bool { mask.kind == .sky && !hasSky }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(mask.label, text: Binding(
                    get: { mask.name ?? "" },
                    set: { mask.name = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12, .semibold)).foregroundColor(Theme.ink)
                    .onSubmit(onChange)
                    .help("Rename this mask")
                if isSelected && mask.kind != .brush {
                    Text("editing on canvas").font(Theme.mono(9)).foregroundColor(Theme.glow)
                }
                Spacer()
                // The off switch, next to the trash rather than instead of it. Same glyph, same
                // help text and same behaviour as the auto masks' eye: click to show where this
                // mask falls, click again to put it away. Tapping the card selects but never
                // deselects — a click that lands on the card's padding should not silently undo
                // your selection — so the deliberate "put it down" gesture needs its own button,
                // and it needs to be the thing you find when you are reaching for the trash.
                Button(action: onToggleSelected) {
                    Image(systemName: isSelected ? "eye.fill" : "eye")
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? Theme.glow : Theme.inkFaint)
                }
                .buttonStyle(.plain)
                .help(isSelected ? "Stop showing this mask on the photo (keeps its edits)"
                                 : "Show where this mask falls")
                // Which mask sits on top of which. Composites in array order, so this changes the
                // picture, not just the list.
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                        .foregroundColor(canMoveUp ? Theme.inkDim : Theme.inkFaint.opacity(0.4))
                }
                .buttonStyle(.plain).disabled(!canMoveUp)
                .help("Move this mask up the stack")
                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .foregroundColor(canMoveDown ? Theme.inkDim : Theme.inkFaint.opacity(0.4))
                }
                .buttonStyle(.plain).disabled(!canMoveDown)
                .help("Move this mask down the stack")
                // Keep this tuning: the mask's settings become a named preset in the add menu.
                // Absent on brush and per-person masks — strokes and people belong to one
                // photograph, and a preset that silently dropped them would be a lie.
                if MaskPreset.isCapturable(mask.kind) {
                    Button(action: onSavePreset) {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 11)).foregroundColor(Theme.inkDim)
                    }
                    .buttonStyle(.plain)
                    .help("Save these settings as a preset")
                }
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundColor(Theme.inkDim)
                }.buttonStyle(.plain)
            }

            if needsPersonButHasNone || needsSkyButHasNone {
                // Same glyph and colour as the craft flags under the preview — one visual language
                // for "look at this", wherever it turns up.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9)).foregroundColor(Theme.warn)
                    Text(needsSkyButHasNone
                         ? "No sky detected in this photo — this mask has nothing to act on."
                         : "No person detected in this photo — this mask has nothing to act on.")
                        .font(Theme.mono(9)).foregroundColor(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch mask.kind {
            case .brush:
                HStack(spacing: 8) {
                    Button(action: togglePaint) {
                        Text(isPainting ? "Painting…" : "Paint")
                            .font(Theme.ui(11, .semibold)).foregroundColor(isPainting ? Theme.base : Theme.ink)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(isPainting ? Theme.glow : Theme.surface2)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1)))
                    }.buttonStyle(.plain)
                    Button(action: clearStrokes) {
                        Text("Clear").font(Theme.ui(11, .semibold)).foregroundColor(Theme.inkDim)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface2)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1)))
                    }.buttonStyle(.plain)
                }
                // ADD / ERASE. Until `BrushStamp.erase` existed a mask could only grow, so a mask
                // that grabbed too much had to be deleted and redrawn. This is also the hand
                // correction for a wand that leaked: paint on the rock, switch to Erase, take the
                // spill back off the sky.
                Picker("", selection: brushMode) {
                    Text("Add").tag(false)
                    Text("Erase").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ToneSlider(label: "Brush size", value: brushRadius, range: 0.02...0.35, step: 0.01, unit: "", onChange: {}, neutral: 0.09)
            case .wand:
                Text("Click the thing you want. The selection spreads from there until the "
                     + "picture stops matching — it stays inside whatever you pointed at.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: toggleSeeding) {
                    Text(isSeeding ? "Click the photo… (esc)" : "Pick a point on the photo")
                        .font(Theme.ui(11, .semibold)).foregroundColor(isSeeding ? Theme.base : Theme.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(isSeeding ? Theme.glow : Theme.surface2)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1)))
                }.buttonStyle(.plain)
                // TOLERANCE IS THE WHOLE CONTROL, and it is not guessable — measured on a real
                // frame, an isolated sea stack holds steady from 0.04 to 0.15 and then the fill
                // bursts into the sky. So the useful range is the low end, finely stepped, and the
                // top of the slider is deliberately short of "everything".
                ToneSlider(label: "Tolerance", value: $mask.wandTolerance, range: 0.01...0.5,
                           step: 0.005, unit: "", onChange: onChange, neutral: 0.10)
                ToneSlider(label: "Edge", value: $mask.wandSoftness, range: 0...1, step: 0.01,
                           unit: "", onChange: onChange, neutral: 0.25)
                ToneSlider(label: "Seed X", value: $mask.cx, range: 0...1, step: 0.005, unit: "", onChange: onChange)
                ToneSlider(label: "Seed Y", value: $mask.cy, range: 0...1, step: 0.005, unit: "", onChange: onChange)
            case .radial:
                ToneSlider(label: "Center X", value: $mask.cx, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Center Y", value: $mask.cy, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Size", value: $mask.radius, range: 0.05...1.2, step: 0.01, unit: "", onChange: onChange, neutral: 0.35)
                ToneSlider(label: "Softness", value: $mask.softness, range: 0...1, step: 0.01, unit: "", onChange: onChange)
            case .linear:
                ToneSlider(label: "Center X", value: $mask.cx, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Center Y", value: $mask.cy, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Angle", value: $mask.angle, range: 0...360, step: 1, unit: "°", onChange: onChange)
                ToneSlider(label: "Softness", value: $mask.softness, range: 0...1, step: 0.01, unit: "", onChange: onChange)
            case .colorRange:
                // Hue picker (0…1 → the colour wheel) + how wide a band + edge softness.
                ToneSlider(label: "Hue", value: $mask.selCenter, range: 0...1, step: 0.005, unit: "", onChange: onChange, identity: .spectrum)
                ToneSlider(label: "Range", value: $mask.selRange, range: 0.01...0.5, step: 0.005, unit: "", onChange: onChange, neutral: 0.1)
                ToneSlider(label: "Softness", value: $mask.selSoftness, range: 0...0.3, step: 0.005, unit: "", onChange: onChange)
            case .luminance:
                ToneSlider(label: "Brightness", value: $mask.selCenter, range: 0...1, step: 0.01, unit: "", onChange: onChange, identity: .exposure)
                ToneSlider(label: "Range", value: $mask.selRange, range: 0.01...0.5, step: 0.005, unit: "", onChange: onChange, neutral: 0.1)
                ToneSlider(label: "Softness", value: $mask.selSoftness, range: 0...0.3, step: 0.005, unit: "", onChange: onChange)
            case .skin:
                Text(mask.instanceId == nil
                     ? (subjectIsPerson
                        ? "Skin tones within the detected person, fair across complexions."
                        : "Skin tones — but no person was detected in this frame, so this has nothing to narrow.")
                     : "Skin tones within \(mask.instanceLabel ?? "this person") only — nobody else's.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                // WHOSE skin, when the frame offers a choice. On a frame with three people a
                // skin edit lands on all of them unless it is told otherwise, and brightening
                // the bride must not also brighten the groom. Hidden with one person — a picker
                // with one real answer is furniture.
                if people.count > 1 {
                    HStack {
                        Text("Whose skin").font(Theme.ui(11)).foregroundColor(Theme.inkDim)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { mask.instanceId ?? "" },
                            set: { chosen in
                                if let person = people.first(where: { $0.id == chosen }) {
                                    mask.instanceId = person.id
                                    mask.instanceLabel = person.label
                                    mask.instanceBox = person.boundingBox
                                    mask.instanceKind = person.kind
                                    if mask.name == nil || mask.name?.hasPrefix("Skin") == true {
                                        mask.name = "Skin — \(person.label)"
                                    }
                                } else {
                                    mask.instanceId = nil; mask.instanceLabel = nil
                                    mask.instanceBox = nil; mask.instanceKind = nil
                                    if mask.name?.hasPrefix("Skin") == true { mask.name = nil }
                                }
                                onChange()
                            })) {
                            Text("Everyone").tag("")
                            ForEach(people, id: \.id) { person in
                                Text(person.label).tag(person.id)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(maxWidth: 170)
                    }
                }
                ToneSlider(label: "Tolerance", value: $mask.selRange, range: 0.02...0.18, step: 0.005, unit: "", onChange: onChange, neutral: 0.06)
            case .background:
                Text("Everything except the detected subject — darken or desaturate it to make the subject pop.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            case .subject:
                // SAYS WHAT WAS ACTUALLY FOUND. This read "The detected person" unconditionally,
                // over a mask that is whatever Vision found most salient — and on the frame this was
                // reported against, that was a sea stack. Applying the person-shaped preset to it
                // (+0.3 EV) put a white rim around the rock, which is a surprising result only
                // because the card had promised a person.
                Text(subjectIsPerson
                     ? "The detected person — lift, model, or recover them without touching the scene."
                     : "The main object \(Branding.displayName) could isolate — not a person in this frame, so lift it gently: a large exposure change through a soft edge shows as a halo.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            case .instance:
                Text("Just this one — everything else in the frame is untouched.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            case .sky:
                Text("The detected sky — darken it, cool it, or bring the weather in, without touching the land.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            // MODIFIERS — the same two on every mask, whatever defines its region. `.skin` and
            // `.background` used to be separate mask kinds, which is what made these unavailable
            // everywhere else: "the highlights within this person" or "everything except the
            // reds" had no way to be said.
            Toggle(isOn: $mask.invert) {
                Text("Invert — adjust everything else")
                    .font(Theme.ui(11)).foregroundColor(Theme.inkDim)
            }
            .toggleStyle(.switch).tint(Theme.glow)
            .onChange(of: mask.invert) { onChange() }

            HStack(spacing: 6) {
                Text("REFINE").font(Theme.mono(9)).tracking(1.2).foregroundColor(Theme.inkFaint)
                Spacer()
                Picker("", selection: $mask.refinement) {
                    Text("Off").tag(UserMaskVM.Refinement.none)
                    Text("Colour").tag(UserMaskVM.Refinement.colour)
                    Text("Light").tag(UserMaskVM.Refinement.luminance)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170).controlSize(.small)
                .onChange(of: mask.refinement) { onChange() }
            }
            .help("Narrow this mask to pixels that are also a certain colour or brightness")

            if mask.refinement != .none {
                ToneSlider(label: mask.refinement == .colour ? "Hue" : "Brightness",
                           value: $mask.refineCenter, range: 0...1, step: 0.005, unit: "",
                           onChange: onChange,
                           identity: mask.refinement == .colour ? .spectrum : .exposure)
                ToneSlider(label: "Range", value: $mask.refineRange, range: 0.01...0.5,
                           step: 0.005, unit: "", onChange: onChange, neutral: 0.12)
                ToneSlider(label: "Softness", value: $mask.refineSoftness, range: 0...0.3,
                           step: 0.005, unit: "", onChange: onChange)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)
            // Built from the SAME list the auto-mask panel uses, rather than a hand-written
            // subset. These two editors had drifted: the auto masks offered six adjustments and
            // hand-drawn ones offered three, so half the renderer's local capability was
            // unreachable on the masks people actually draw. Driving both from
            // `maskAdjustmentSpecs` is what stops that happening again — add a control there and
            // it appears in both places, with the same range and the same label.
            ForEach(AppState.maskAdjustmentSpecs, id: \.key) { spec in
                ToneSlider(label: spec.label,
                           value: Binding(get: { mask[adjustment: spec.key] },
                                          set: { mask[adjustment: spec.key] = $0 }),
                           range: spec.range,
                           step: spec.key == "exposure_ev" ? 0.05 : 1,
                           unit: spec.unit,
                           onChange: onChange,
                           identity: ToneIdentity.adjustment(spec.key),
                           onDragging: { $0 ? onAdjustBegin() : onAdjustEnd() })
            }
            ToneSlider(label: "Tightness", value: $mask.tightness, range: 0...100, step: 1, unit: "", onChange: onChange)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke((isPainting || isSelected) ? Theme.glow : Theme.glow.opacity(0.4),
                            lineWidth: (isPainting || isSelected) ? 1.5 : 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

// MARK: - Mask control (toggle + strength for an auto-mask)

struct MaskControl: View {
    let name: String
    @Binding var isOn: Bool
    @Binding var strength: Double
    let onChange: () -> Void
    /// The full local adjustment set for this mask. Optional so the control still works for
    /// callers that only want the toggle.
    var maskId: String? = nil
    var adjustment: ((String) -> Binding<Double>)? = nil
    var feather: Binding<Double>? = nil
    var tightness: Binding<Double>? = nil
    var invert: Binding<Bool>? = nil
    var onReset: (() -> Void)? = nil
    /// Whether this mask is the one the overlay is showing, and how to say "show me this one".
    /// Clicking a selected mask again clears the selection, which is what puts the red away.
    var isSelected: Bool = false
    var onSelect: () -> Void = {}
    /// Bracket a tone drag so the overlay can step aside while the picture is being judged.
    var onAdjustBegin: () -> Void = {}
    var onAdjustEnd: () -> Void = {}
    /// Folded by default. A subject mask usually needs nothing beyond the strength Kelvin chose,
    /// and six sliders per mask unfolded would rebuild the wall of controls the sidebar just lost.
    @State private var showAdjustments = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: $isOn) {
                    Text(name).font(Theme.ui(13, .medium)).foregroundColor(Theme.ink)
                }
                .toggleStyle(.switch).tint(Theme.glow)
                .onChange(of: isOn) { onChange() }
                Spacer()
                // Show-me-this-one, and click again to put it away. The auto masks previously had
                // no way to say either: the overlay picked one on its own and the panel offered
                // nothing to change or clear that choice.
                Button(action: onSelect) {
                    Image(systemName: isSelected ? "eye.fill" : "eye")
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? Theme.glow : Theme.inkFaint)
                }
                .buttonStyle(.plain)
                .help(isSelected ? "Hide this mask's overlay" : "Show where this mask falls")
            }

            if isOn {
                HStack {
                    Text("Strength").font(Theme.ui(11)).foregroundColor(Theme.inkDim)
                    Spacer()
                    Text("\(Int(strength))%").font(Theme.mono(10)).foregroundColor(Theme.glow)
                }
                // Live, like every `ToneSlider`. Commit-on-release here alone made the one control
                // in the panel that does not preview read as a control that does not work.
                Slider(value: $strength, in: 0...100, step: 1)
                    .onChange(of: strength) { onChange() }
                    .tint(Theme.glow).controlSize(.small)

                if let adjustment {
                    Button {
                        withAnimation(Motion.gated(Motion.quick, reduceMotion)) { showAdjustments.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                                .rotationEffect(.degrees(showAdjustments ? 90 : 0))
                            Text("Adjust").font(Theme.mono(9, .semibold)).tracking(1)
                            Spacer()
                            if onReset != nil && showAdjustments {
                                Button("Reset") { onReset?() }
                                    .buttonStyle(.plain)
                                    .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                            }
                        }
                        .foregroundColor(Theme.inkDim)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showAdjustments {
                        VStack(spacing: 10) {
                            ForEach(AppState.maskAdjustmentSpecs, id: \.key) { spec in
                                ToneSlider(label: spec.label,
                                           value: adjustment(spec.key),
                                           range: spec.range,
                                           step: spec.key == "exposure_ev" ? 0.05 : 1,
                                           unit: spec.unit,
                                           onChange: onChange,
                                           identity: ToneIdentity.adjustment(spec.key),
                                           onDragging: { $0 ? onAdjustBegin() : onAdjustEnd() })
                            }
                            if let feather {
                                ToneSlider(label: "Feather", value: feather, range: 0...100,
                                           step: 1, unit: "", onChange: onChange)
                            }
                            if let tightness {
                                ToneSlider(label: "Tightness", value: tightness, range: 0...100,
                                           step: 1, unit: "", onChange: onChange)
                            }
                            if let invert {
                                Toggle(isOn: invert) {
                                    Text("Invert — adjust everything else")
                                        .font(Theme.ui(11)).foregroundColor(Theme.inkDim)
                                }
                                .toggleStyle(.switch).tint(Theme.glow)
                                .onChange(of: invert.wrappedValue) { onChange() }
                            }
                        }
                        .padding(.top, 2)
                        .transition(.opacity)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Theme.glow.opacity(0.6) : Theme.hairline.opacity(0.6),
                            lineWidth: isSelected ? 1.5 : 1))
        )
    }
}

// MARK: - Keyboard Shortcuts Sheet

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    // Grouped, because this list stopped being scannable at about eight rows. The headings are the
    // same ones the panel uses, so the sheet reads in the order the work happens.
    private let shortcuts: [(key: String, description: String)] = [
        ("— CULLING —", ""),
        ("P  or  Z", "Flag as Keep & advance"),
        ("X", "Flag as Reject & advance"),
        ("U", "Clear this photo's flag"),
        ("← / →", "Previous / next photo"),
        ("— CHOOSING FRAMES —", ""),
        ("⌘-click", "Add or remove one frame from the selection"),
        ("⇧-click", "Extend the selection to this frame"),
        ("⌘A / ⇧⌘A", "Select every frame / clear the selection"),
        ("— LOOKING —", ""),
        ("1 – 4", "Select candidate 1, 2, 3 or 4"),
        ("\\", "Toggle the original (or hold 'Hold to compare')"),
        ("Space", "Zoom to the last ratio, or back to fit"),
        ("⌘= / ⌘−", "Zoom in / out"),
        ("/", "Show or hide the filmstrip"),
        ("— MASKS —", ""),
        ("B / L / R", "Add a brush, linear or radial mask"),
        ("⇧C / ⇧I", "Add a colour-range or luminance mask"),
        ("O", "Show or hide the red mask overlay"),
        ("⌘I", "Invert the selected mask"),
        ("[ / ]", "Brush size down / up"),
        ("⇧[ / ⇧]", "Feather the selected mask in / out"),
        ("— REPAIR —", ""),
        ("H", "Heal tool on / off"),
        ("[ / ]", "Heal size down / up (while healing)"),
        ("⌥-click", "Remove the patch under the pointer"),
        ("— EDITING —", ""),
        ("⌘Z / ⌘⇧Z", "Undo / redo"),
        ("⌘R", "Reset every slider to the candidate"),
        ("— FILES —", ""),
        ("⇧E", "Export this photo"),
        ("⌘O", "Open another photo or folder"),
        ("⌘/", "Show this list")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("KEYBOARD SHORTCUTS")
                    .font(Theme.mono(11, .semibold)).tracking(1.4).foregroundColor(Theme.ink)
                Spacer()
                Button("Done") { dismiss() }
                    .font(Theme.ui(12, .semibold)).foregroundColor(Theme.glow)
                    .buttonStyle(.plain)
            }
            Divider().overlay(Theme.hairline)

            VStack(spacing: 9) {
                ForEach(shortcuts, id: \.key) { item in
                    if item.description.isEmpty {
                        Text(item.key.replacingOccurrences(of: "—", with: "").trimmingCharacters(in: .whitespaces))
                            .font(Theme.mono(9, .semibold)).tracking(1.2)
                            .foregroundColor(Theme.inkFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } else {
                    HStack(spacing: 12) {
                        Text(item.key)
                            .font(Theme.mono(10, .semibold))
                            .foregroundColor(Theme.base)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.glow))
                            .frame(width: 76, alignment: .leading)
                        Text(item.description)
                            .font(Theme.ui(12)).foregroundColor(Theme.ink)
                        Spacer()
                    }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.surface)
    }
}
