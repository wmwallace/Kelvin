import Foundation

/// The single source of truth for anything user- or file-facing that carries the product
/// identity. Per CLAUDE.md ("Naming"), the rename before first external user must be a
/// one-line-per-value change — so do NOT hardcode any of these strings anywhere else.
///
/// The name is settled as "Kelvin" (docs/DECISIONS.md D9). This file exists anyway, and its
/// discipline matters MORE now rather than less: the name was chosen in the knowledge that another
/// product in this category holds it, so the cost of a rename — should one ever be forced — is a
/// risk that was accepted rather than eliminated. Keeping every user-facing occurrence funnelled
/// through here is what bounds that cost at a day instead of a week.
///
/// Eight user-visible strings used to bypass this constant, including the default export filename,
/// so the "one-line rename" the docs promised was never true. It is now.
///
/// Note for anyone doing that rename: "Kelvin" is ALSO the SI unit, used legitimately in about forty
/// places in the colour-temperature code (`KelvinScale`, `CraftFix`, the temperature rail). A
/// find-and-replace would corrupt every one of them. The product name lives here; the unit is
/// physics and stays.
public enum Branding {
    /// Human-readable product name shown in UI, `--help`, and logs.
    public static let displayName = "Kelvin"

    /// The stem of the fallback export filename, for when there is no source file to name the
    /// output after. Lowercased and hyphenated rather than `displayName`, because it lands on a
    /// filesystem: "kelvin-edit.jpg".
    public static let exportStem = displayName.lowercased() + "-edit"

    /// Reverse-DNS bundle identifier. Treated as sacred once users exist (CLAUDE.md):
    /// changing it orphans preferences, keychain entries, and the sandbox container.
    ///
    /// This said `com.kelvin.app` while `scripts/package-app.sh` shipped `dev.kelvin.app` in the
    /// Info.plist, and nothing read this constant, so nothing caught it. macOS keys the
    /// preferences domain, the sandbox container and LaunchServices off the *plist*, so the
    /// packaged app's real identity was always the `dev.` one — this is the value that matches
    /// what is installed, and the packaging script now reads it from here rather than repeating
    /// it. Aligning in this direction rather than the other keeps every `@AppStorage` setting
    /// already on disk attached to the app that wrote it.
    ///
    /// NOW `app.usekelvin.kelvin` — the reverse-DNS of `usekelvin.app`, which this project owns
    /// (D11). It got here in two steps on the same day: it said `dev.kelvin.app`, which is the
    /// reverse-DNS of a domain registered to somebody else entirely, then briefly
    /// `io.github.wmwallace.kelvin` while no domain was owned at all.
    ///
    /// The domain is the better namespace precisely because it carries no extra risk: `usekelvin.app`
    /// has to stay renewed regardless, since the Sparkle appcast URL lives there and every shipped
    /// copy checks it forever. A GitHub-derived identifier would have been free but tied to an
    /// account name rather than to the product.
    ///
    /// **THIS WAS THE LAST CHEAP MOMENT AND IT IS NOW SPENT.** No external user existed when it
    /// changed, so nothing was orphaned. After the first alpha install, macOS keys the preferences
    /// domain, the sandbox container and LaunchServices off this exact string — changing it then
    /// strands every setting, every flag and every sidecar those users have, silently. Do not touch
    /// it again, including if the product is ever renamed: a bundle identifier is an identity, not a
    /// label, and keeping a stale-looking one is far cheaper than orphaning a user's work.
    public static let bundleIdentifier = "app.usekelvin.kelvin"

    /// File extension for recipe sidecars (no leading dot). Expensive to change once
    /// sidecars exist in the wild, so it lives here from commit one.
    public static let sidecarExtension = "kelvin"

    // MARK: Where to send someone
    //
    // Here rather than in the views, for the same reason the display name is: a URL repeated in
    // four places is a URL that will be wrong in three of them. These open in the user's browser
    // when clicked — the app itself never fetches them.

    public static let repositoryURL = "https://github.com/wmwallace/Kelvin"
    public static let releasesURL = repositoryURL + "/releases"
    public static let issuesURL = repositoryURL + "/issues"
    public static let licenceName = "AGPL-3.0-only"

    /// Where "Support development" points, once there is somewhere to point.
    ///
    /// `nil` on purpose, and the settings pane hides the whole section while it is nil — an empty
    /// "Sponsors" heading in a pre-alpha app reads as unfinished, and it would be the first thing
    /// in a screenshot. Set it when sponsorship actually exists; nothing else needs to change.
    public static let sponsorURL: String? = nil
}
