#!/usr/bin/env bash
# Build the delta patch that turns the PREVIOUS release into this one.
#
#   scripts/make-delta.sh <old .app or .dmg> <new .app> [out-dir]
#
# Typical use, after scripts/package-app.sh has produced a notarised dist/Kelvin.app:
#
#   gh release download v0.1.0 --pattern '*.dmg' --dir /tmp
#   scripts/make-delta.sh /tmp/Kelvin-0.1.0.dmg dist/Kelvin.app
#
# It writes a signed `.delta`, proves the patch reconstructs the new app exactly, and prints the
# <sparkle:deltas> block to paste into appcast.xml.
#
# WHY THIS IS NOT OPTIONAL. The perception weights ship inside the bundle (D-model-5), so the app
# is ~1.7 GB and the disk image ~1.4 GB. Without a delta, a one-line bug fix asks every installed
# copy to download 1.4 GB again — which teaches people to decline updates, and an updater users
# decline is worse than no updater. Nearly all of that payload is 4-bit safetensors that do not
# change between releases, so a code-only update is a few megabytes once the unchanged files are
# skipped.
#
# WHAT SPARKLE ACTUALLY MATCHES ON. `sparkle:deltaFrom` is looked up against the INSTALLED app's
# CFBundleVersion — the build number, not the marketing version:
#
#     deltaUpdateFromAppcastItem:regularItem hostVersion:_host.version   (SUAppcastDriver.m)
#     appcastItem.deltaUpdates[hostVersion]
#
# and `SUHost.version` reads CFBundleVersion. This project's build number is the commit count, so
# for the 0.1.0 release it is 191 and NOT "0.1.0". Writing the marketing version there produces an
# appcast that validates, publishes and silently never matches anybody. This script reads the number
# out of the old bundle rather than letting anyone type it.
#
# The failure mode is at least kind: if the delta is missing, mis-keyed or fails to apply, Sparkle
# falls back to the full enclosure ("Failed to download delta update. Falling back to regular
# update…"). So a mistake here costs bandwidth, not a broken install.
#
# ONE DELTA PER SHIPPED PREDECESSOR. A patch is a pair, not a version: a user still on the release
# before last matches no `deltaFrom` and takes the full download. Generate a delta from every
# release still plausibly installed and list them all inside one <sparkle:deltas>.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ $# -lt 2 ]; then
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
OLD_INPUT="$1"; NEW_APP="$2"; OUT="${3:-$ROOT/dist}"

[ -e "$OLD_INPUT" ] || { echo "make-delta.sh: no such file: $OLD_INPUT" >&2; exit 1; }
[ -d "$NEW_APP" ]   || { echo "make-delta.sh: the new app is not a bundle: $NEW_APP" >&2; exit 1; }

# The Sparkle command-line tools live in SwiftPM's artifacts directory, which is wherever the last
# build put it — package-app.sh uses its own scratch path. Look in the usual places, then anywhere.
find_sparkle_bin() {
  local candidate
  for candidate in \
    "${KELVIN_SPARKLE_BIN:-}" \
    "$ROOT/Integrations/KelvinPerceptionMLX/.build/artifacts/sparkle/Sparkle/bin" \
    "${TMPDIR:-/tmp}kelvin-package-build/artifacts/sparkle/Sparkle/bin"
  do
    [ -n "$candidate" ] && [ -x "$candidate/BinaryDelta" ] && { printf '%s' "$candidate"; return; }
  done
  candidate="$(find "${TMPDIR:-/tmp}" "$ROOT" -type d -path "*sparkle/Sparkle/bin" 2>/dev/null | head -1)"
  [ -n "$candidate" ] && printf '%s' "$candidate"
}
SPARKLE_BIN="$(find_sparkle_bin)"
if [ -z "$SPARKLE_BIN" ]; then
  echo "make-delta.sh: cannot find Sparkle's BinaryDelta." >&2
  echo "  Build the app package once (scripts/package-app.sh) so SwiftPM fetches the artifact," >&2
  echo "  or point KELVIN_SPARKLE_BIN at the directory holding BinaryDelta and sign_update." >&2
  exit 1
fi

# A .dmg is what actually shipped, so it is the honest source for "what the user has installed".
# Mounted read-only and read in place — BinaryDelta only reads the before-tree, and copying 1.7 GB
# back out would cost minutes for nothing.
MOUNT=""
cleanup() { [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; }
trap cleanup EXIT
case "$OLD_INPUT" in
  *.dmg)
    echo "▸ Mounting $(basename "$OLD_INPUT")…"
    MOUNT="$(hdiutil attach "$OLD_INPUT" -nobrowse -readonly | tail -1 | awk '{print $NF}')"
    OLD_APP="$(find "$MOUNT" -maxdepth 1 -name "*.app" -type d | head -1)"
    [ -n "$OLD_APP" ] || { echo "make-delta.sh: no .app inside $OLD_INPUT" >&2; exit 1; }
    ;;
  *) OLD_APP="$OLD_INPUT" ;;
esac

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
OLD_BUILD="$(plist_value "$OLD_APP" CFBundleVersion)"
OLD_SHORT="$(plist_value "$OLD_APP" CFBundleShortVersionString)"
NEW_BUILD="$(plist_value "$NEW_APP" CFBundleVersion)"
NEW_SHORT="$(plist_value "$NEW_APP" CFBundleShortVersionString)"
for v in "$OLD_BUILD" "$OLD_SHORT" "$NEW_BUILD" "$NEW_SHORT"; do
  [ -n "$v" ] || { echo "make-delta.sh: could not read versions from both bundles" >&2; exit 1; }
done
# Sparkle ignores an update whose CFBundleVersion does not exceed the installed one, so a delta
# between equal or descending build numbers is a patch nothing will ever ask for.
if [ "$NEW_BUILD" -le "$OLD_BUILD" ] 2>/dev/null; then
  echo "make-delta.sh: the new build number ($NEW_BUILD) does not exceed the old one ($OLD_BUILD)." >&2
  echo "  Sparkle would never offer this update at all. Check you passed old first, new second." >&2
  exit 1
fi

NAME="$(basename "$NEW_APP" .app)"
mkdir -p "$OUT"
DELTA="$OUT/$NAME-$NEW_SHORT-from-$OLD_BUILD.delta"
rm -f "$DELTA"

echo "▸ $OLD_SHORT (build $OLD_BUILD)  →  $NEW_SHORT (build $NEW_BUILD)"
echo "▸ Creating $(basename "$DELTA")…"
# Version 4 is BinaryDelta's default and is what the Sparkle inside the shipped app understands —
# both come from the same pinned Sparkle release. Do NOT raise this past what the OLDEST app that
# will be offered the patch carries: the patch is read by the version of Sparkle already on disk,
# not the one being installed.
"$SPARKLE_BIN/BinaryDelta" create "$OLD_APP" "$NEW_APP" "$DELTA"

DELTA_BYTES="$(stat -f%z "$DELTA")"
FULL_BYTES="$(du -sm "$NEW_APP" | cut -f1)"
# `stat` rather than `du -h`, which reports ALLOCATED blocks — it calls an 87 KB patch 148 KB, and
# the number that matters is the one going into the appcast's `length`. The leading newline is
# because BinaryDelta's last warning, when it emits one, is not newline-terminated.
printf '\n✓ %s — %s against a %s MB bundle\n' "$(basename "$DELTA")" \
  "$(awk -v b="$DELTA_BYTES" 'BEGIN{ if (b>=1048576) printf "%.1f MB", b/1048576; else printf "%.0f KB", b/1024 }')" \
  "$FULL_BYTES"
# A delta this size means the weights moved, since nothing else in the bundle is big enough to
# produce one. That is legitimate when the perception model is replaced — but it is worth knowing
# before it is published, because at some point the patch stops being cheaper than the download.
if [ "$DELTA_BYTES" -gt 104857600 ]; then
  echo "  NOTE: over 100 MB. Something large changed — replaced weights? Check that a patch this" >&2
  echo "  size is still worth serving instead of the full image." >&2
fi

# PROVE IT, rather than trusting that it worked. A delta that applies to something other than the
# new app is not detectable from the appcast, only from a user whose copy stops launching — and the
# whole reason a patch is cheap is that it rewrites only some of the bundle, which is exactly the
# operation that can leave the signature covering contents that no longer match.
VERIFY="${TMPDIR:-/tmp}kelvin-delta-verify"
rm -rf "$VERIFY"
echo "▸ Applying the patch to a scratch copy and comparing…"
"$SPARKLE_BIN/BinaryDelta" apply "$OLD_APP" "$VERIFY" "$DELTA"
if ! diff -r --no-dereference "$NEW_APP" "$VERIFY" >/dev/null; then
  echo "make-delta.sh: the patched bundle DIFFERS from the new app. Do not ship this delta." >&2
  diff -r --no-dereference "$NEW_APP" "$VERIFY" 2>&1 | head -20 >&2
  exit 1
fi
# Byte-identical is necessary but not sufficient: the signature has to survive being reassembled
# from a patch, and only codesign can say so.
if ! codesign --verify --deep --strict "$VERIFY" 2>&1; then
  echo "make-delta.sh: the patched bundle does not pass codesign. Do not ship this delta." >&2
  exit 1
fi
echo "✓ patched copy is byte-identical and still verifies"
rm -rf "$VERIFY"

# SIGN IT. Every enclosure Sparkle downloads is verified against the public key baked into the
# shipped Info.plist, deltas included; an unsigned one is refused and falls back to the full update.
#
# `-f <keyfile>` rather than the Keychain: reading the key from the login Keychain raises an
# authorisation dialog, and when this runs without a visible session sign_update simply HANGS on it.
# The backed-up copy of the private key is the reliable path. It is not in the repository and must
# never be.
KEYFILE="${KELVIN_SPARKLE_KEYFILE:-$HOME/Documents/Code/kelvin support/sparkle_private_key}"
# An array, not a string: the backup lives in a directory with a space in its name, and unquoted
# word splitting would hand sign_update two nonexistent paths.
if [ -f "$KEYFILE" ]; then
  KEY_ARGS=(-f "$KEYFILE")
else
  echo "  no key file at $KEYFILE — falling back to the Keychain, which may block on a prompt." >&2
  KEY_ARGS=()
fi
echo "▸ Signing the delta…"
SIGNED="$("$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$DELTA")"
SIGNATURE="$(printf '%s' "$SIGNED" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$SIGNATURE" ] || { echo "make-delta.sh: sign_update produced no signature: $SIGNED" >&2; exit 1; }
# Check the signature against the file it is about to be published for. Free, and the alternative
# way to discover a signature that does not match — a stale key, the wrong file — is a user whose
# update is refused and silently downgraded to a 1.4 GB download.
if ! "$SPARKLE_BIN/sign_update" --verify "$DELTA" "$SIGNATURE" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} >/dev/null 2>&1; then
  echo "make-delta.sh: the signature does not verify against the delta. Do not publish it." >&2
  exit 1
fi

REPO_URL="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -e 's/\.git$//' -e 's#git@github.com:#https://github.com/#')"
REPO_URL="${REPO_URL:-https://github.com/wmwallace/Kelvin}"

cat <<XML

Upload $(basename "$DELTA") to the v$NEW_SHORT release alongside the disk image, then put this
inside that release's <item> in appcast.xml, after its <enclosure>:

    <sparkle:deltas>
      <enclosure
        url="$REPO_URL/releases/download/v$NEW_SHORT/$(basename "$DELTA")"
        sparkle:deltaFrom="$OLD_BUILD"
        sparkle:edSignature="$SIGNATURE"
        length="$DELTA_BYTES"
        type="application/octet-stream"/>
    </sparkle:deltas>

XML
