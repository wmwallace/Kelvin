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

echo "▸ Building kelvin-app ($CONFIG)…"
( cd "$PKG" && swift build -c "$CONFIG" --product kelvin-app )
BUILD="$PKG/.build/$CONFIG"

APP="$OUT/Kelvin.app"
echo "▸ Assembling $APP"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/kelvin-app" "$APP/Contents/MacOS/"
# MLX + friends locate resources (incl. default.metallib) via Bundle.module next to the exe.
cp -R "$BUILD"/*.bundle "$APP/Contents/MacOS/" 2>/dev/null || true
cp "$PKG/AppIcon/Kelvin.icns" "$APP/Contents/Resources/Kelvin.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Kelvin</string>
  <key>CFBundleDisplayName</key><string>Kelvin</string>
  <key>CFBundleExecutable</key><string>kelvin-app</string>
  <key>CFBundleIdentifier</key><string>dev.kelvin.app</string>
  <key>CFBundleIconFile</key><string>Kelvin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

echo "▸ Ad-hoc code-signing…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"   # nudge Finder/LaunchServices to refresh the icon
echo "✓ $APP"
