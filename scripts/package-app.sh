#!/usr/bin/env bash
# Package Kelvin.app — a double-clickable macOS bundle with the icon and the MLX resources.
#
#   scripts/package-app.sh [--debug] [out-dir]
#
# By default builds release. Bundles the executable, the SwiftPM resource bundles (which
# carry MLX's default.metallib), the icon, an Info.plist, and ad-hoc code-signs.
#
# NOTE: live perception works when the app is launched from the package via
#   `cd Integrations/KelvinPerceptionMLX && swift run kelvin-app`.
# The bundle launches fine (empty state, correct icon), but the FIRST perceive() —
# loading the 2.9 GB model — terminates with NO crash report (ruled out: icon/Bundle.module,
# metallib/resources, code-signing, foreground role). A SIGKILL with no report points at
# jetsam/memory pressure or an MLX-in-GUI abort; diagnose on-device with Activity Monitor
# (watch memory during load) or Console (filter for jetsam / the kelvin-app process).
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

echo "▸ Building kelvin-app ($CONFIG)…"
( cd "$PKG" && swift build -c "$CONFIG" --product kelvin-app )
BUILD="$PKG/.build/$CONFIG"

APP="$OUT/$NAME.app"
echo "▸ Assembling $APP"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/kelvin-app" "$APP/Contents/MacOS/"
# MLX + friends locate resources (incl. default.metallib) via Bundle.module next to the exe.
cp -R "$BUILD"/*.bundle "$APP/Contents/MacOS/" 2>/dev/null || true
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
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

# iCloud/file-provider volumes stamp com.apple.FinderInfo onto build products, and codesign
# refuses to sign anything carrying it (see the Makefile header). Strip it rather than let the
# signature fail.
xattr -cr "$APP" 2>/dev/null || true

echo "▸ Ad-hoc code-signing…"
# Not `|| true`: this used to swallow its own output and its exit code, so a bundle that failed
# to sign was reported as "✓" and only announced itself later as a launch failure.
if ! codesign --force --deep --sign - "$APP"; then
  echo "package-app.sh: code-signing failed — $APP will not launch" >&2
  exit 1
fi
touch "$APP"   # nudge Finder/LaunchServices to refresh the icon
echo "✓ $APP"
