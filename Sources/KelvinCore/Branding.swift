import Foundation

/// The single source of truth for anything user- or file-facing that carries the product
/// identity. Per CLAUDE.md ("Naming"), the rename before first external user must be a
/// one-line-per-value change — so do NOT hardcode any of these strings anywhere else.
///
/// The current values use the working name "Kelvin" (see docs/DECISIONS.md D9). Naming is
/// still deferred; only these three constants and the SwiftPM product name should need to
/// change when it is settled.
public enum Branding {
    /// Human-readable product name shown in UI, `--help`, and logs.
    public static let displayName = "Kelvin"

    /// Reverse-DNS bundle identifier. Treated as sacred once users exist (CLAUDE.md):
    /// changing it orphans preferences, keychain entries, and the sandbox container.
    public static let bundleIdentifier = "com.kelvin.app"

    /// File extension for recipe sidecars (no leading dot). Expensive to change once
    /// sidecars exist in the wild, so it lives here from commit one.
    public static let sidecarExtension = "kelvin"
}
