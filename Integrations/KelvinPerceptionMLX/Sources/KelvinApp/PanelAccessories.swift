import AppKit
import KelvinCore

/// The controls that live inside an open or save panel, in AppKit rather than SwiftUI.
///
/// **This is not a style preference.** A `NSHostingView` inside a panel's `accessoryView` renders,
/// and then stops updating: `runModal()` spins the run loop in `NSModalPanelRunLoopMode`, which is
/// not the mode SwiftUI drives its view updates on. The checkbox was reported as impossible to
/// untick — and the truth was worse than that, because the click WAS landing and the stored
/// preference WAS flipping. Only the tick stayed where it was. So the setting could end up the exact
/// opposite of what the panel showed, and an export could quietly carry a location the user believed
/// they had just switched off.
///
/// AppKit controls in a modal panel are one of the few remaining places where the old framework is
/// simply the correct answer. Nothing here needs a third-party dependency; a checkbox and a pop-up
/// button are thirty lines.
///
/// Every control writes straight through to `AppState`, whose properties persist themselves — so the
/// panel and the Settings window can never disagree about what is set.
@MainActor
enum PanelAccessories {

    // MARK: Open

    /// One checkbox: whether opening a photograph also lists the rest of its folder.
    static func openOptions(_ state: AppState) -> NSView {
        let container = FlippedView()
        let checkbox = NSButton(checkboxWithTitle: "Include the rest of the folder",
                                target: OpenTarget.shared, action: #selector(OpenTarget.toggled(_:)))
        OpenTarget.shared.state = state
        let explanation = NSTextField(wrappingLabelWithString: "")
        OpenTarget.shared.explanation = explanation
        checkbox.state = state.includeFolderOnOpen ? .on : .off
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor
        OpenTarget.shared.refresh()

        container.addSubview(checkbox)
        container.addSubview(explanation)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        explanation.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 460),
            checkbox.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            checkbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            explanation.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 4),
            explanation.leadingAnchor.constraint(equalTo: checkbox.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            explanation.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    /// A target-action sink. `@objc` selectors need a class, and the panel outlives the call that
    /// built it, so this holds the state rather than capturing it.
    @MainActor
    private final class OpenTarget: NSObject {
        static let shared = OpenTarget()
        weak var state: AppState?
        var explanation: NSTextField?

        @objc func toggled(_ sender: NSButton) {
            state?.includeFolderOnOpen = (sender.state == .on)
            refresh()
        }

        func refresh() {
            guard let state else { return }
            explanation?.stringValue = state.includeFolderOnOpen
                ? "The other photos are listed in the strip below. Nothing is read from them until the strip is open."
                : "Only the photo you pick — no filmstrip, no arrow keys, and no way to apply a look to the shoot."
        }
    }

    // MARK: Export

    // NOTE: `batchOptions` lived here, the accessory for a panel that no longer exists — applying a
    // look to the shoot writes a record and asks for no folder, so there is nothing to hang an
    // accessory off. Its one control, the Keep-flag scope, moved into the toolbar beside the Apply
    // button, where it can say what it will do before you press anything.

    /// `showScope` adds the "kept only" row and belongs only on the export-EDITED panel — a scope
    /// choice over many photos is meaningless when the panel is exporting exactly one.
    static func exportOptions(_ state: AppState, showScope: Bool = false,
                              savePanel: NSSavePanel? = nil) -> NSView {
        let container = FlippedView()
        let target = ExportTarget.shared
        target.state = state
        target.savePanel = savePanel
        target.suggestedName = savePanel?.nameFieldStringValue

        let format = NSPopUpButton()
        format.addItems(withTitles: ["JPEG", "HEIC", "PNG", "TIFF 16-bit"])
        format.selectItem(at: ["jpeg", "heic", "png", "tiff16"].firstIndex(of: state.exportFormatId) ?? 0)
        format.target = target; format.action = #selector(ExportTarget.formatChanged(_:))

        let size = NSPopUpButton()
        for (title, _) in ExportTarget.sizes { size.addItem(withTitle: title) }
        size.selectItem(at: ExportTarget.sizes.firstIndex { $0.1 == state.exportLongEdge } ?? 0)
        size.target = target; size.action = #selector(ExportTarget.sizeChanged(_:))

        let space = NSPopUpButton()
        for option in ImageWriter.ColorSpace.allCases { space.addItem(withTitle: option.label) }
        space.selectItem(at: ImageWriter.ColorSpace.allCases.firstIndex { $0.rawValue == state.exportColorSpaceId } ?? 0)
        space.target = target; space.action = #selector(ExportTarget.spaceChanged(_:))

        let quality = NSSlider(value: state.exportQuality, minValue: 0.4, maxValue: 1,
                               target: target, action: #selector(ExportTarget.qualityChanged(_:)))
        quality.isContinuous = true
        // A HORIZONTAL NSSlider HAS NO NATURAL WIDTH. Left to its intrinsic size inside a stack it
        // collapses to about the width of its own knob, which is why this rendered as a stray blob
        // sitting on top of the number instead of a slider: there was nothing to slide along.
        quality.translatesAutoresizingMaskIntoConstraints = false
        quality.widthAnchor.constraint(equalToConstant: 118).isActive = true
        let qualityLabel = NSTextField(labelWithString: "\(Int(state.exportQuality * 100))")
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        let location = NSButton(checkboxWithTitle: "Remove location and camera serial",
                                target: target, action: #selector(ExportTarget.locationChanged(_:)))
        location.state = state.stripLocationOnExport ? .on : .off

        target.quality = quality
        target.qualityLabel = qualityLabel
        target.refresh()

        // HOW THE FILES GET NAMED, decided where the files are being written.
        //
        // The four schemes existed but lived only in Settings, which is the wrong room: naming is a
        // property of THIS export — the shoot you are delivering now — and a setting you last
        // touched a month ago is not a decision you are making. It matters most on the group panel,
        // where one click writes hundreds of names and there is no save field to correct them in.
        let naming = NSPopUpButton()
        for scheme in ExportNaming.Scheme.allCases { naming.addItem(withTitle: scheme.label) }
        naming.selectItem(at: ExportNaming.Scheme.allCases.firstIndex { $0 == state.exportNaming } ?? 0)
        naming.target = target; naming.action = #selector(ExportTarget.namingChanged(_:))
        // A word in FRONT and a word at the END, both optional and both live. The scheme decides
        // what Kelvin contributes; these are what the photographer contributes, and they are the
        // two positions a delivery folder actually needs — sort-by-client wants the front, and
        // "which round of edits is this" wants the end.
        let prefix = NSTextField(string: state.exportPrefix)
        prefix.placeholderString = "Optional — e.g. a client"
        prefix.target = target; prefix.action = #selector(ExportTarget.prefixChanged(_:))
        let suffix = NSTextField(string: state.exportSuffix)
        suffix.placeholderString = "Optional — e.g. v2"
        suffix.target = target; suffix.action = #selector(ExportTarget.suffixChanged(_:))
        target.prefixField = prefix
        target.suffixField = suffix
        // Live, for the same reason the label is: a modal accessory gets no second chance to tell
        // you what it did, and `action` alone fires only on Enter or focus loss — so typing a
        // prefix and clicking Export immediately would have exported without it.
        for field in [prefix, suffix] {
            NotificationCenter.default.addObserver(
                target, selector: #selector(ExportTarget.affixEditing(_:)),
                name: NSControl.textDidChangeNotification, object: field)
        }

        let namingExample = NSTextField(labelWithString: "")
        namingExample.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        namingExample.textColor = .secondaryLabelColor
        target.namingExample = namingExample
        target.refreshNamingExample()

        var rows: [[NSView]] = [
            [NSTextField(labelWithString: "Format:"), format,
             NSTextField(labelWithString: "Size:"), size],
            [NSTextField(labelWithString: "Colour:"), space,
             NSTextField(labelWithString: "Quality:"), stack(quality, qualityLabel)],
            [NSTextField(labelWithString: "Name:"), naming,
             NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Prefix:"), prefix,
             NSTextField(labelWithString: "Suffix:"), suffix],
            [NSGridCell.emptyContentView, namingExample,
             NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, location, NSGridCell.emptyContentView, NSGridCell.emptyContentView]
        ]
        if showScope {
            // The photographer's own word for this export. Only on the group panel: labelling a
            // batch is the whole use — one photo is already being given a name in the save field
            // above, and two places to name one file is a way to disagree with yourself.
            //
            // The preview updates as it is typed, because the sanitiser lowercases and hyphenates:
            // "Lake Como, Day 2" becomes `lake-como-day-2`, and finding that out after four hundred
            // files exist is exactly the kind of surprise this panel is supposed to prevent.
            let label = NSTextField(string: state.exportLabel)
            label.placeholderString = "Optional — a place, a client, an event"
            label.target = target
            label.action = #selector(ExportTarget.labelChanged(_:))
            // Live, not just on Enter: an accessory in a modal panel does not get a second chance
            // to tell you what it did.
            NotificationCenter.default.addObserver(
                target, selector: #selector(ExportTarget.labelEditing(_:)),
                name: NSControl.textDidChangeNotification, object: label)
            let labelPreview = NSTextField(labelWithString: "")
            labelPreview.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            labelPreview.textColor = .secondaryLabelColor
            target.labelField = label
            target.labelPreview = labelPreview
            target.refreshLabelPreview()
            rows.append([NSTextField(labelWithString: "Label:"), label,
                         NSGridCell.emptyContentView, NSGridCell.emptyContentView])
            rows.append([NSGridCell.emptyContentView, labelPreview,
                         NSGridCell.emptyContentView, NSGridCell.emptyContentView])

            // Which photos, chosen with the flags the filmstrip already has: P marks a keeper
            // (the culling keys are P/X, straight from the shortcuts sheet — a string here once
            // said K, promising a key nobody bound, which is a mistake this codebase has already
            // paid for once). The count is in the title because a scope control that doesn't say
            // how many it selects is a guessing game.
            //
            // Counted off the EXPORT TARGETS, not off the hand-edited frames: a shoot carried by an
            // applied look has plenty to export and nothing "edited", and this read "0 of 0" over a
            // panel that was about to write four hundred files.
            let keeperTargets = state.exportTargets(keepersOnly: true).count
            let allTargets = state.exportableCount
            let keepers = NSButton(
                checkboxWithTitle: "Only photos flagged Keep (\(keeperTargets) of \(allTargets))",
                target: target, action: #selector(ExportTarget.keepersChanged(_:)))
            keepers.state = state.exportKeepersOnly ? .on : .off
            if keeperTargets == 0 {
                keepers.isEnabled = false
                keepers.state = .off
                state.exportKeepersOnly = false
                keepers.toolTip = "Flag photos first — press P on each, or click the flag on "
                + "its filmstrip tile — and this becomes a choice"
            }
            rows.append([NSGridCell.emptyContentView, keepers,
                         NSGridCell.emptyContentView, NSGridCell.emptyContentView])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 1).width = 150
        grid.column(at: 3).width = 150
        // From the naming EXAMPLE down. The Name popup itself stays in the 150-wide column so it
        // lines up with Format and Colour above it rather than stretching across the panel.
        for mergedRow in 3..<rows.count {
            grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 3),
                            verticalRange: NSRange(location: mergedRow, length: 1))
        }

        container.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 520),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }

    private static func stack(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    @MainActor
    private final class ExportTarget: NSObject {
        static let shared = ExportTarget()
        static let sizes: [(String, Int)] = [
            ("Full resolution", 0), ("4096 px", 4096), ("2048 px", 2048),
            ("1600 px", 1600), ("1080 px", 1080)
        ]
        weak var state: AppState?
        var quality: NSSlider?
        var qualityLabel: NSTextField?

        @objc func formatChanged(_ sender: NSPopUpButton) {
            state?.exportFormatId = ["jpeg", "heic", "png", "tiff16"][sender.indexOfSelectedItem]
            refresh()
        }
        @objc func sizeChanged(_ sender: NSPopUpButton) {
            state?.exportLongEdge = Self.sizes[sender.indexOfSelectedItem].1
        }
        @objc func spaceChanged(_ sender: NSPopUpButton) {
            state?.exportColorSpaceId = ImageWriter.ColorSpace.allCases[sender.indexOfSelectedItem].rawValue
        }
        @objc func qualityChanged(_ sender: NSSlider) {
            state?.exportQuality = sender.doubleValue
            refresh()
        }
        @objc func locationChanged(_ sender: NSButton) {
            state?.stripLocationOnExport = (sender.state == .on)
        }
        @objc func keepersChanged(_ sender: NSButton) {
            state?.exportKeepersOnly = (sender.state == .on)
        }

        weak var labelField: NSTextField?
        weak var labelPreview: NSTextField?

        @objc func labelChanged(_ sender: NSTextField) {
            state?.exportLabel = sender.stringValue
            refreshLabelPreview()
        }

        /// Fired on every keystroke via `NSControl.textDidChangeNotification`. The field's `action`
        /// only fires on Enter or focus loss, and someone who types a label and clicks Export
        /// immediately would otherwise have exported without it.
        @objc func labelEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField, field === labelField else { return }
            state?.exportLabel = field.stringValue
            refreshLabelPreview()
        }

        func refreshLabelPreview() {
            guard let state else { return }
            if let token = state.exportLabelPreview {
                labelPreview?.stringValue = "→ _DSC6595_\(token)…"
            } else {
                labelPreview?.stringValue = ""
            }
            refreshNamingExample()
        }

        // MARK: Naming

        weak var namingExample: NSTextField?
        /// The save panel this accessory belongs to, when there is one — only the single-photo
        /// export has a filename field to keep in step.
        weak var savePanel: NSSavePanel?
        /// The last name this accessory put in that field, so a name the photographer typed
        /// themselves is never overwritten by a scheme change. Changing the scheme asks for a new
        /// suggestion; it does not ask to lose what you wrote.
        var suggestedName: String?

        weak var prefixField: NSTextField?
        weak var suffixField: NSTextField?

        @objc func prefixChanged(_ sender: NSTextField) {
            state?.exportPrefix = sender.stringValue
            refreshNamingExample(); syncSavePanelName()
        }
        @objc func suffixChanged(_ sender: NSTextField) {
            state?.exportSuffix = sender.stringValue
            refreshNamingExample(); syncSavePanelName()
        }
        @objc func affixEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            if field === prefixField { state?.exportPrefix = field.stringValue }
            else if field === suffixField { state?.exportSuffix = field.stringValue }
            else { return }
            refreshNamingExample(); syncSavePanelName()
        }

        @objc func namingChanged(_ sender: NSPopUpButton) {
            state?.exportNamingId = ExportNaming.Scheme.allCases[sender.indexOfSelectedItem].rawValue
            refreshNamingExample()
            syncSavePanelName()
        }

        /// Show the name this export will actually produce, for the photo in hand — not a canned
        /// illustration. On the group panel it stands for every file the click is about to write.
        func refreshNamingExample() {
            guard let state else { return }
            let real = state.imageURL == nil
                ? nil : state.suggestedExportName(ext: state.exportFormat.fileExtension)
            namingExample?.stringValue = real ?? state.exportNaming.example
        }

        func syncSavePanelName() {
            guard let state, let panel = savePanel, state.imageURL != nil else { return }
            let next = state.suggestedExportName(ext: state.exportFormat.fileExtension)
            // Only when the field still holds what we last put there.
            guard panel.nameFieldStringValue == suggestedName || suggestedName == nil else { return }
            panel.nameFieldStringValue = next
            suggestedName = next
        }

        /// A quality control beside PNG or TIFF is a control that does nothing, which is the exact
        /// thing this codebase keeps finding and removing.
        func refresh() {
            guard let state else { return }
            let lossy = state.exportFormat.isLossy
            quality?.isEnabled = lossy
            qualityLabel?.stringValue = lossy ? "\(Int(state.exportQuality * 100))" : "—"
            qualityLabel?.textColor = lossy ? .labelColor : .tertiaryLabelColor
            // The format decides the extension, so the suggested name moves with it.
            refreshNamingExample()
            syncSavePanelName()
        }
    }

    /// Panels lay their accessory out from the top; a flipped view stops the contents appearing
    /// upside-down relative to the constraints above.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
