import AppKit
import KelvinCore

/// Whether this process is the installed app or something built from source, and how to make that
/// obvious at a glance.
///
/// **Written because two Kelvins on screen cost real time.** A packaged 0.3.0 from `/Applications`
/// and a `swift run` build from the working tree look identical — same icon, same window, same
/// wordmark — so a report of "the natural edit no longer looks natural" could not be attributed to
/// either one without going to `ps` and comparing start times against a build log. The answer
/// mattered: one build had an experimental change in it and the other predated the day's work
/// entirely.
///
/// This is a development affordance and it costs a shipped build nothing: `isDevelopmentBuild` is
/// false for anything a user installs, so every branch here is dead code in a release.
enum BuildIdentity {

    /// True when this is not the installed, packaged app.
    ///
    /// Keyed on the bundle identifier rather than on `#if DEBUG`, deliberately. A `swift run` build
    /// has no `Info.plist` and therefore no identifier at all, while `make app` in release
    /// configuration is still a working-tree build that should be marked — the useful question is
    /// "is this the app someone installed", not "which optimisation level was it compiled at".
    /// Same test `DefaultAppPrompt` uses to decide whether it can offer to be the default handler.
    static var isDevelopmentBuild: Bool {
        Bundle.main.bundleIdentifier != Branding.bundleIdentifier
    }

    /// The short marker shown beside the wordmark. Nil in a release, so the header stays clean.
    static var badge: String? { isDevelopmentBuild ? "DEV" : nil }

    /// The dock icon, badged when this is a working-tree build.
    ///
    /// A badge rather than a tint of the whole icon: the icon is a colour-temperature gradient, so
    /// tinting it would read as a design change rather than a warning, and at Dock size a subtle wash
    /// is invisible anyway.
    ///
    /// The first attempt was a bare triangle covering 42% of the icon, drawn straight onto the corner
    /// of a rounded mark. It spilled outside the icon's own silhouette — a hard right-angle sticking
    /// out past a squircle — and looked like a rendering fault rather than a badge. Asked about
    /// directly: "is this how it is meant to look". It was not.
    ///
    /// This one is a dot, inset well within the icon's bounds so it cannot touch the corner geometry
    /// at all, with a dark ring so it reads against both the warm and the cool end of the gradient
    /// underneath. Round beats a wedge here for one boring reason: a circle has no corners to
    /// disagree with the icon's.
    static func applicationIcon() -> NSImage? {
        guard let data = Data(base64Encoded: AppIconData.base64),
              let icon = NSImage(data: data) else { return nil }
        guard isDevelopmentBuild else { return icon }
        return badged(icon)
    }

    /// Exposed so the badge can be rendered and looked at without launching the app.
    static func badged(_ icon: NSImage) -> NSImage {
        let size = icon.size
        let side = min(size.width, size.height)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: CGRect(origin: .zero, size: size))

        // ANCHORED TO THE ARTWORK, NOT THE CANVAS. A macOS `.icns` carries transparent padding around
        // the squircle — the icon grid — so a margin measured from the image edge puts the badge on
        // or outside the visible mark. Measured here instead: the opaque bounding box is found and
        // the dot is inset from that. This was the second thing wrong with the first badge, and it is
        // invisible at authoring size and obvious in the Dock.
        let art = opaqueBounds(of: icon) ?? CGRect(origin: .zero, size: size)
        let artSide = min(art.width, art.height)
        let diameter = artSide * 0.30
        let margin = artSide * 0.06
        let box = CGRect(x: art.maxX - margin - diameter,
                         y: art.minY + margin,
                         width: diameter, height: diameter)

        // A dark ring first, so the dot separates from whatever it lands on.
        NSColor(calibratedWhite: 0.08, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: box.insetBy(dx: -side * 0.018, dy: -side * 0.018)).fill()

        // Amber rather than red: "not the installed build" is a fact to notice, not a failure to
        // worry about.
        NSColor(calibratedRed: 0.98, green: 0.68, blue: 0.15, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: box).fill()

        out.unlockFocus()
        return out
    }

    /// The bounding box of everything in `image` that is not fully transparent, in the image's own
    /// coordinate space (origin bottom-left, to match `NSImage` drawing).
    ///
    /// Nil when the image is empty or cannot be rasterised, which the caller treats as "the artwork
    /// fills the canvas" — the harmless assumption, and the one that was implicitly being made before.
    static func opaqueBounds(of image: NSImage) -> CGRect? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.bitmapData else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0, rep.samplesPerPixel == 4 else { return nil }
        let rowBytes = rep.bytesPerRow, spp = rep.samplesPerPixel
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = data + y * rowBytes
            for x in 0..<w where row[x * spp + 3] > 8 {      // 8/255: ignore antialiasing dust
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Bitmap rows run top-down; NSImage drawing is bottom-up. Flip Y on the way out.
        let scaleX = image.size.width / Double(w), scaleY = image.size.height / Double(h)
        return CGRect(x: Double(minX) * scaleX,
                      y: Double(h - 1 - maxY) * scaleY,
                      width: Double(maxX - minX + 1) * scaleX,
                      height: Double(maxY - minY + 1) * scaleY)
    }
}
