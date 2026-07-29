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
    /// A corner flash rather than a tint of the whole icon: the icon is a colour-temperature gradient,
    /// so tinting it would read as a design change rather than a warning, and at Dock size a subtle
    /// wash is invisible anyway. A hard wedge in one corner survives being 32 pixels tall, which is
    /// the only size that matters for telling two Dock entries apart.
    static func applicationIcon() -> NSImage? {
        guard let data = Data(base64Encoded: AppIconData.base64),
              let icon = NSImage(data: data) else { return nil }
        guard isDevelopmentBuild else { return icon }
        return badged(icon)
    }

    private static func badged(_ icon: NSImage) -> NSImage {
        let size = icon.size
        let out = NSImage(size: size)
        out.lockFocus()
        icon.draw(in: CGRect(origin: .zero, size: size))

        // Bottom-right corner, on the diagonal, so it never sits over the middle of the mark.
        let side = min(size.width, size.height)
        let wedge = NSBezierPath()
        let inset = side * 0.42
        wedge.move(to: CGPoint(x: size.width - inset, y: 0))
        wedge.line(to: CGPoint(x: size.width, y: 0))
        wedge.line(to: CGPoint(x: size.width, y: inset))
        wedge.close()
        // Amber rather than red: this is "not the installed build", which is a fact to notice, not a
        // failure to worry about.
        NSColor(calibratedRed: 0.95, green: 0.6, blue: 0.1, alpha: 0.95).setFill()
        wedge.fill()

        out.unlockFocus()
        return out
    }
}
