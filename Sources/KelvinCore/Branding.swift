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
    /// NOW `io.github.wmwallace.kelvin`, and the change is deliberate. `dev.kelvin.app` is the
    /// reverse-DNS of `kelvin.dev`, a domain this project does not own and cannot obtain — it is
    /// registered to someone else. A reverse-DNS identifier is conventionally a namespace you
    /// control; `wmwallace.github.io` is one, it costs nothing, and it does not depend on renewing a
    /// registration forever.
    ///
    /// This is the LAST cheap moment to change it. No external user exists, so nothing is orphaned
    /// today. After the first alpha install, macOS keys the preferences domain, the sandbox
    /// container and LaunchServices off this string, and changing it strands every setting and
    /// sidecar those users have. Do not touch it again.
    public static let bundleIdentifier = "io.github.wmwallace.kelvin"

    /// File extension for recipe sidecars (no leading dot). Expensive to change once
    /// sidecars exist in the wild, so it lives here from commit one.
    public static let sidecarExtension = "kelvin"
}
