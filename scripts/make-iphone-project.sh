#!/bin/sh
# Generate the iPhone app's Xcode project from Apps/KelvinPhone/project.yml (XcodeGen, MIT).
#
# The name and identifier come from Branding.swift, never repeated here — the same reader
# package-app.sh uses, for the reason it gives: a name written twice drifts.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANDING="$ROOT/Sources/KelvinCore/Branding.swift"
branding_value() {
  v="$(sed -n "s/.*static let $1 = \"\([^\"]*\)\".*/\1/p" "$BRANDING" | head -1)"
  [ -n "$v" ] || { echo "make-iphone-project.sh: could not read '$1' from $BRANDING" >&2; exit 1; }
  printf '%s' "$v"
}
command -v xcodegen >/dev/null || { echo "make-iphone-project.sh: needs XcodeGen (brew install xcodegen)" >&2; exit 1; }
export KELVIN_DISPLAY_NAME="$(branding_value displayName)"
export KELVIN_IPHONE_BUNDLE_ID="$(branding_value iPhoneBundleIdentifier)"
# The team that signs the Mac release; override for a personal team.
export KELVIN_TEAM="${KELVIN_TEAM:-9YG69NV2WX}"
export KELVIN_VERSION="${KELVIN_VERSION:-0.1.0}"
cd "$ROOT/Apps/KelvinPhone"
xcodegen generate --quiet
echo "✓ Apps/KelvinPhone/KelvinPhone.xcodeproj ($KELVIN_DISPLAY_NAME, $KELVIN_IPHONE_BUNDLE_ID)"
