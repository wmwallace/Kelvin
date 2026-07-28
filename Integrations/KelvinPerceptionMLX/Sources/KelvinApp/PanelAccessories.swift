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
    static func exportOptions(_ state: AppState, showScope: Bool = false) -> NSView {
        let container = FlippedView()
        let target = ExportTarget.shared
        target.state = state

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
        let qualityLabel = NSTextField(labelWithString: "\(Int(state.exportQuality * 100))")
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        let location = NSButton(checkboxWithTitle: "Remove location and camera serial",
                                target: target, action: #selector(ExportTarget.locationChanged(_:)))
        location.state = state.stripLocationOnExport ? .on : .off

        target.quality = quality
        target.qualityLabel = qualityLabel
        target.refresh()

        var rows: [[NSView]] = [
            [NSTextField(labelWithString: "Format:"), format,
             NSTextField(labelWithString: "Size:"), size],
            [NSTextField(labelWithString: "Colour:"), space,
             NSTextField(labelWithString: "Quality:"), stack(quality, qualityLabel)],
            [NSGridCell.emptyContentView, location, NSGridCell.emptyContentView, NSGridCell.emptyContentView]
        ]
        if showScope {
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
        for mergedRow in 2..<rows.count {
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

        /// A quality control beside PNG or TIFF is a control that does nothing, which is the exact
        /// thing this codebase keeps finding and removing.
        func refresh() {
            guard let state else { return }
            let lossy = state.exportFormat.isLossy
            quality?.isEnabled = lossy
            qualityLabel?.stringValue = lossy ? "\(Int(state.exportQuality * 100))" : "—"
            qualityLabel?.textColor = lossy ? .labelColor : .tertiaryLabelColor
        }
    }

    /// Panels lay their accessory out from the top; a flipped view stops the contents appearing
    /// upside-down relative to the constraints above.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
