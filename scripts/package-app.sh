#!/usr/bin/env bash
# Package Kelvin.app — a double-clickable macOS bundle with the icon and the MLX resources.
#
#   scripts/package-app.sh [--debug] [out-dir]
#
# By default builds release. Bundles the executable, the SwiftPM resource bundles (which
# carry MLX's default.metallib), the icon, an Info.plist, and ad-hoc code-signs.
#
# THE LAUNCH FAILURE IS FIXED, AND IT WAS NEITHER OF THE THINGS THIS COMMENT USED TO BLAME.
#
# For months the bundle launched fine — empty state, correct icon — and then died on the FIRST
# perceive() with no crash report, and this header recorded code-signing as "ruled out" with
# jetsam/memory pressure as the likely cause. Both were wrong, and the evidence was already
# visible in the symptom:
#
#   * A JETSAM KILL WRITES A REPORT to ~/Library/Logs/DiagnosticReports. "No crash report" was
#     evidence AGAINST memory pressure the whole time, not for it.
#   * Watching RSS while it died settled it: the process expired at 230 MB, three seconds in, on
#     a 16 GB machine — before the 1.6 GB of weights had even been mapped.
#
# The actual cause, from running the bundled binary in a terminal where its stderr was visible:
#
#     MLX error: Failed to load the default metallib. library not found  (mlx/c/stream.cpp:115)
#
# MLX's `load_default_library` (mlx/backend/metal/device.cpp) tries five locations, and the only
# one that can find a SwiftPM resource bundle looks inside `NS::Bundle::mainBundle()` and each
# bundle's **resourceURL** — i.e. `Contents/Resources/`. This script copied the bundles next to the
# executable in `Contents/MacOS/`, which is exactly right for `swift run` (where the executable's
# directory IS the bundle root, so Bundle.module resolves) and cannot work inside a .app. So MLX
# found no metallib, threw, and took the process down before any Swift error handling ran.
#
# Moving the bundles to Contents/Resources fixes it, and fixes the SwiftPM `Bundle.module`
# accessors for swift-transformers and swift-crypto at the same time, for the same reason: they
# search `Bundle.main.resourceURL` too. Verified end to end — RSS peaks at ~2.0 GB as the model
# loads, settles at ~530 MB, and the window shows generated candidates.
#
# THE LESSON WORTH KEEPING: a hard C++ abort inside a dependency produces no crash report and no
# Swift error. When a GUI process dies silently, run its binary directly in a terminal and read
# stderr before theorising about the kernel.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Integrations/KelvinPerceptionMLX"
CONFIG="release"; OUT="$ROOT/dist"
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    *) OUT="$arg" ;;
  esac
done

# The product name and bundle ID are read from Branding.swift, never repeated here. CLAUDE.md
# requires the rename to be a one-line-per-value change, and this script was the counter-example:
# it hardcoded the name four times and shipped `dev.kelvin.app` while the constant said
# `com.kelvin.app`. Nothing in Swift read the constant, so nothing caught the drift — and since
# macOS keys the preferences domain and sandbox container off the plist, the constant was simply
# wrong about the app's own identity.
BRANDING="$ROOT/Sources/KelvinCore/Branding.swift"
branding_value() {
  local v
  v="$(sed -n "s/.*static let $1 = \"\([^\"]*\)\".*/\1/p" "$BRANDING" | head -1)"
  [ -n "$v" ] || { echo "package-app.sh: could not read '$1' from $BRANDING" >&2; exit 1; }
  printf '%s' "$v"
}
NAME="$(branding_value displayName)"
BUNDLE_ID="$(branding_value bundleIdentifier)"

VERSION="${KELVIN_VERSION:-0.1.0}"
# Monotonic without a file to remember to bump. Falls back to 1 outside a git checkout.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
COPYRIGHT="© $(date +%Y) William Wallace. Licensed under AGPL-3.0-only; source at https://github.com/wmwallace/Kelvin"

echo "▸ Building kelvin-app ($CONFIG)…"
( cd "$PKG" && swift build -c "$CONFIG" --product kelvin-app )
BUILD="$PKG/.build/$CONFIG"

APP="$OUT/$NAME.app"
echo "▸ Assembling $APP"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/kelvin-app" "$APP/Contents/MacOS/"
# INTO Contents/Resources, NOT Contents/MacOS — see the header. MLX searches each bundle's
# `resourceURL` for default.metallib, and SwiftPM's `Bundle.module` accessors search
# `Bundle.main.resourceURL`. Both mean Contents/Resources inside a .app. Putting these next to the
# executable is what `swift run` wants and is silently fatal in a bundle.
if ! cp -R "$BUILD"/*.bundle "$APP/Contents/Resources/" 2>/dev/null; then
  echo "package-app.sh: no SwiftPM resource bundles found in $BUILD" >&2
  echo "  the app cannot load MLX's metallib without them and will die on first perceive()" >&2
  exit 1
fi
# Fail loudly rather than shipping a bundle that dies three seconds after a user opens a photo.
if [ ! -f "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
  echo "package-app.sh: default.metallib is not where MLX looks for it" >&2
  exit 1
fi
# The .icns is still named for the product on disk; renaming the app means renaming that file
# too. One `git mv`, and the rest of this script follows the constant.
cp "$PKG/AppIcon/$NAME.icns" "$APP/Contents/Resources/$NAME.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>kelvin-app</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <!-- CFBundleVersion must increase monotonically for Sparkle to recognise an update at all, and
       it must never be reused. The commit count is monotonic by construction and needs no manual
       bookkeeping. -->
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

# iCloud/file-provider volumes stamp com.apple.FinderInfo onto build products, and codesign
# refuses to sign anything carrying it (see the Makefile header). Strip it rather than let the
# signature fail.
xattr -cr "$APP" 2>/dev/null || true

# Signing. Ad-hoc by default, which is enough to launch locally; a real Developer ID identity —
# required for anyone else to open the app without Gatekeeper refusing it — comes from the
# environment:
#
#   KELVIN_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/package-app.sh
#
# `security find-identity -v -p codesigning` lists what is available.
IDENTITY="${KELVIN_SIGN_IDENTITY:--}"
SIGN_OPTS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  # Hardened runtime + a secure timestamp are both prerequisites for notarisation. Worth turning
  # on as early as possible: the hardened runtime restricts exactly what MLX does (compiling Metal
  # kernels at runtime), so if an entitlement turns out to be needed, discover it now.
  SIGN_OPTS+=(--options runtime --timestamp)
fi

echo "▸ Code-signing (${IDENTITY})…"
# INSIDE-OUT, not `--deep`. Apple documents --deep as unsuitable for signing — it applies the
# outer options to nested code and is a verification convenience at best. Nested bundles get
# signed first, the app last, so the app's seal covers finished contents.
#
# Not `|| true`: this used to swallow its own exit code, so a bundle that failed to sign was
# reported as "✓" and only announced itself later as a launch failure.
while IFS= read -r nested; do
  codesign "${SIGN_OPTS[@]}" "$nested" >/dev/null 2>&1 || {
    echo "package-app.sh: failed to sign nested bundle $nested" >&2; exit 1; }
done < <(find "$APP/Contents/Resources" -maxdepth 1 -name "*.bundle" -type d)

if ! codesign "${SIGN_OPTS[@]}" "$APP"; then
  echo "package-app.sh: code-signing failed — $APP will not launch" >&2
  exit 1
fi

# Verify what was actually produced rather than trusting that it worked. `--deep` IS appropriate
# here: for verification it is exactly the recursive check wanted.
if ! codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2; then
  echo "package-app.sh: the bundle does not verify" >&2
  exit 1
fi
if [ "$IDENTITY" != "-" ]; then
  echo "▸ Gatekeeper assessment:"
  spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/    /' || \
    echo "    (rejected — expected until the build is notarised)"
  echo "    Next: xcrun notarytool submit --wait, then xcrun stapler staple '$APP'"
fi
touch "$APP"   # nudge Finder/LaunchServices to refresh the icon
echo "✓ $APP"
