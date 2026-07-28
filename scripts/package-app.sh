#!/usr/bin/env bash
# Package Kelvin — a double-clickable .app, and the .dmg a user downloads.
#
#   scripts/package-app.sh [--debug] [out-dir]
#
# Local development build (ad-hoc signed, no notarisation, no weights required):
#   scripts/package-app.sh
#
# Release build (self-contained, signed, notarised, stapled, plus a signed disk image):
#   make stage-model
#   KELVIN_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
#   KELVIN_NOTARY_PROFILE=kelvin-notary \
#     scripts/package-app.sh
#
# Environment:
#   KELVIN_SIGN_IDENTITY   signing identity; ad-hoc ("-") when unset
#   KELVIN_NOTARY_PROFILE  notarytool keychain profile; skips notarisation when unset
#   KELVIN_VERSION         CFBundleShortVersionString (default 0.1.0)
#   KELVIN_DMG=0           skip building the disk image
#
# Measured on a release build with the weights inside: app 1.7 GB, dmg 1.4 GB, ~1 min to build the
# image, and the notary service takes roughly fifteen minutes per submission at that size. There are
# TWO submissions — the app and then the image — and the ordering is deliberate; see the dmg section.
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
APPCAST_URL="$(branding_value appcastURL)"

# Sparkle's EdDSA PUBLIC key — safe to bake in here; the private half lives in the login
# Keychain ("Private key for signing Sparkle updates", written by Sparkle's generate_keys,
# 26 July 2026) and must never enter the repository. Every update is signed with the private
# key and verified by installed copies against this one; leaking the private key lets someone
# else push updates to every user, and losing it means shipped copies refuse all future updates.
SPARKLE_PUBKEY="${KELVIN_SPARKLE_PUBKEY:-Xj6oAUueYtrxVSSc0gIp9ykY05r0oNMgDTL6DNgSiPI=}"

VERSION="${KELVIN_VERSION:-0.1.0}"
# Monotonic without a file to remember to bump. Falls back to 1 outside a git checkout.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
COPYRIGHT="© $(date +%Y) William Wallace. Licensed under AGPL-3.0-only; source at https://github.com/wmwallace/Kelvin"

# A SEPARATE SCRATCH PATH, so packaging does not fight the editor. SwiftPM takes an exclusive lock
# on a build directory, so a packaging run using the package's own `.build` blocks `swift run
# kelvin-app` with "Another instance of SwiftPM is already running" — at exactly the moment someone
# is trying to test. Override with KELVIN_BUILD_PATH.
SCRATCH="${KELVIN_BUILD_PATH:-${TMPDIR:-/tmp}kelvin-package-build}"
echo "▸ Building kelvin-app ($CONFIG)…"
( cd "$PKG" && swift build -c "$CONFIG" --product kelvin-app --scratch-path "$SCRATCH" )
BUILD="$SCRATCH/$CONFIG"

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

# THE PERCEPTION WEIGHTS SHIP INSIDE THE APP. One artifact, no first-run download, no third party,
# and — the reason that actually decided it — the model is pinned to the release rather than to
# whatever a remote repository points at today. `ModelConfiguration(id:)` resolves revision "main",
# so a re-quantisation upstream would silently change perception behaviour for new users of an
# already-shipped build. Weights that travel with the binary cannot do that.
#
# `MLXPerceptionProvider.bundledModelDirectory` looks exactly here, and finding it means no network
# call is ever made — `loadModelContainer` only constructs a Downloader for the `.id` case.
#
# Staged by `make stage-model`, which refuses to stage weights whose LICENSE is absent, because
# shipping them is redistribution. Kept out of git: 1.6 GB does not belong in every clone.
MODEL_SRC="$ROOT/Vendor/PerceptionModel"
if [ -d "$MODEL_SRC" ] && [ -f "$MODEL_SRC/config.json" ]; then
  echo "▸ Bundling perception weights ($(du -sh "$MODEL_SRC" | cut -f1))…"
  # -c asks for APFS clonefile: copy-on-write, so this is instant and costs no extra disk until
  # codesign touches something. Falls back to a real copy on filesystems without it.
  cp -Rc "$MODEL_SRC" "$APP/Contents/Resources/PerceptionModel" 2>/dev/null || \
    cp -R "$MODEL_SRC" "$APP/Contents/Resources/PerceptionModel"
elif [ "${KELVIN_SIGN_IDENTITY:--}" != "-" ]; then
  # A RELEASE BUILD MUST BE SELF-CONTAINED. Without this guard, forgetting `make stage-model` would
  # produce a signed, notarised app that looks correct, ships, and then reaches for Hugging Face on
  # a user's machine — the exact behaviour this design exists to remove, discovered by a stranger.
  echo "package-app.sh: no staged weights at $MODEL_SRC, and this is a signed build." >&2
  echo "  Run 'make stage-model' first. A release must not depend on a download." >&2
  exit 1
else
  echo "▸ No staged weights — this build will fetch them at runtime (dev builds only)."
  echo "  Run 'make stage-model' to bundle them."
fi
# The .icns is still named for the product on disk; renaming the app means renaming that file
# too. One `git mv`, and the rest of this script follows the constant.
cp "$PKG/AppIcon/$NAME.icns" "$APP/Contents/Resources/$NAME.icns"

# SPARKLE TRAVELS AS A FRAMEWORK, and the bundle must carry it: SwiftPM links the executable
# against @rpath/Sparkle.framework, and the only rpath a user's machine can satisfy is one
# inside the app. Copied from SwiftPM's artifacts, given an rpath the bundle can honour, and
# signed inside-out below like everything else that executes.
SPARKLE_FW="$BUILD/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
  SPARKLE_FW="$(find "$SCRATCH/artifacts" -type d -name "Sparkle.framework" -path "*macos*" 2>/dev/null | head -1)"
fi
if [ -z "$SPARKLE_FW" ] || [ ! -d "$SPARKLE_FW" ]; then
  echo "package-app.sh: Sparkle.framework not found under $SCRATCH/artifacts" >&2
  echo "  The app links against it and will not launch without it." >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/kelvin-app" 2>/dev/null || true

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
  <!-- Sparkle. The feed URL comes from Branding.appcastURL and is FROZEN once any binary
       ships — every installed copy checks it forever.

       UPDATES ARE AUTOMATIC BY DEFAULT, and both switches are in Settings ▸ General for anyone
       who wants them off. This reverses the original stance, which was to ask first and default
       to nothing: an alpha that only updates the people who happened to say yes to a dialog
       leaves known-bad builds running, and every fix shipped after them is theoretical. The
       privacy cost is bounded and stated plainly in SECURITY.md and the README — the check sends
       no identity and carries no telemetry; it is a GET of a few KB of XML, and it says which
       version asked only in as much as any HTTPS request has a user agent.

       SUEnableAutomaticChecks=true also suppresses Sparkle's permission prompt, which is the
       point: the prompt exists to obtain the consent this default already assumes. Leaving the
       prompt AND defaulting to on would be asking a question whose answer is ignored. -->
  <key>SUFeedURL</key><string>$APPCAST_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBKEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
</dict></plist>
PLIST

# A signed build with an empty public key would ship an updater that can never verify an
# update — worse than no updater, because it looks like one. Refuse, same policy as the
# missing-weights guard above.
if [ "${KELVIN_SIGN_IDENTITY:--}" != "-" ] && [ -z "$SPARKLE_PUBKEY" ]; then
  echo "package-app.sh: KELVIN_SPARKLE_PUBKEY is not set, and this is a signed build." >&2
  echo "  Run Sparkle's generate_keys once (docs/RELEASING.md) and export the public key:" >&2
  echo "  KELVIN_SPARKLE_PUBKEY='<base64 public key>'" >&2
  exit 1
fi

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
  # Output NOT swallowed. An earlier version of this loop sent codesign's stderr to /dev/null and
  # reported only "failed to sign nested bundle", which hid the actual cause — the first use of a
  # newly installed private key raises a Keychain prompt, and while that dialog sits unanswered
  # codesign simply blocks, then fails. The message that explains it is the one codesign prints.
  if ! codesign "${SIGN_OPTS[@]}" "$nested"; then
    echo "package-app.sh: failed to sign nested bundle $nested" >&2
    echo "  If this hung first: look for a Keychain dialog and choose Always Allow." >&2
    echo "  In CI there is nobody to click it — import the .p12 into a temporary keychain and run" >&2
    echo "  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <pw> <keychain>" >&2
    exit 1
  fi
done < <(find "$APP/Contents/Resources" -maxdepth 1 -name "*.bundle" -type d)

# Sparkle's framework carries its own executables — the XPC services, Autoupdate, and
# Updater.app — and each must be signed before the framework that contains it, and the
# framework before the app. `find -depth` yields children before parents, which is exactly
# the inside-out order signing needs.
while IFS= read -r nested; do
  if ! codesign "${SIGN_OPTS[@]}" "$nested"; then
    echo "package-app.sh: failed to sign $nested" >&2
    exit 1
  fi
done < <(find "$APP/Contents/Frameworks" -depth \
           \( -name "*.xpc" -o -name "*.app" -o \( -name "Autoupdate" -type f \) -o -name "*.framework" \) 2>/dev/null)

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
# Notarisation. Signing makes the app attributable to you; NOTARISATION is what stops macOS
# refusing to open it on anyone else's machine. Both are required, and a signed-but-unnotarised
# build is rejected by Gatekeeper with `source=Unnotarized Developer ID` — which reads like a
# signing failure and is not one.
#
#   KELVIN_NOTARY_PROFILE=kelvin-notary KELVIN_SIGN_IDENTITY="Developer ID Application: …" \
#     scripts/package-app.sh
#
# Create the profile once with:
#   xcrun notarytool store-credentials "kelvin-notary" --key AuthKey_XXX.p8 --key-id XXX --issuer …
NOTARY_PROFILE="${KELVIN_NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && [ "$IDENTITY" != "-" ]; then
  echo "▸ Notarising (profile: $NOTARY_PROFILE)…"
  # notarytool will not accept a bare .app — it wants a zip, a dmg or a pkg. `ditto -c -k
  # --keepParent` is the required form; `zip -r` mangles symlinks and extended attributes.
  ZIP="$OUT/$NAME-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "package-app.sh: notarisation failed. For the reason, run:" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
  rm -f "$ZIP"
  # Staple the ticket INTO the bundle so it validates with no network. Without this the app still
  # passes on a connected machine and fails for anyone offline — the worst kind of intermittent.
  xcrun stapler staple "$APP"
fi

if [ "$IDENTITY" != "-" ]; then
  echo "▸ Gatekeeper assessment:"
  spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/    /' || true
  if [ -z "$NOTARY_PROFILE" ]; then
    echo "    A rejection here is EXPECTED without notarisation — the signature is fine."
    echo "    Set KELVIN_NOTARY_PROFILE to notarise and staple in the same run."
  fi
fi

# The disk image — what a user actually downloads.
#
# Built AFTER the app has been notarised and stapled, and that order is the point: a stapled app
# validates with NO network, so someone who drags it out of the image and opens it on a plane gets a
# working app rather than a Gatekeeper failure. Build the image first and the app inside it can never
# carry its own ticket, because a mounted image is read-only.
#
# An /Applications symlink makes the window drag-to-install, which is the convention every Mac user
# already knows.
#
# zlib-level=1 rather than maximum: measured on this payload, 4-bit safetensors gave up ~16% however
# hard they were squeezed, and level 1 reaches roughly the same place in a fraction of the time. There
# is nothing to win by compressing high-entropy weights harder.
if [ "${KELVIN_DMG:-1}" = "1" ] && command -v hdiutil >/dev/null; then
  DMG="$OUT/$NAME-$VERSION.dmg"
  STAGE="$OUT/.dmg-stage"
  # Braces are load-bearing: bash treats the bytes of the following ellipsis as part of the
  # identifier, so "$DMG…" expands a variable called DMG… — unset, and fatal under set -u.
  # This line is why the disk image had never once been built.
  echo "▸ Building ${DMG}…"
  rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
  cp -Rc "$APP" "$STAGE/" 2>/dev/null || cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov \
    -format UDZO -imagekey zlib-level=1 "$DMG"
  rm -rf "$STAGE"

  # The image is itself code-signable and worth signing: a downloaded, unsigned disk image can warn
  # on mount even when the app inside is perfect.
  if [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    if [ -n "$NOTARY_PROFILE" ]; then
      # A SECOND submission, and there is no way around it for a bundled-weights app: the ticket for
      # the app cannot cover the image that did not exist yet when it was issued. Apple's guidance is
      # to notarise the image as well.
      echo "▸ Notarising the disk image…"
      if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo "package-app.sh: the disk image failed notarisation. For the reason:" >&2
        echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
      fi
      xcrun stapler staple "$DMG"
      echo "▸ Disk image assessment:"
      spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/    /' || true
    fi
  fi
  echo "✓ $DMG ($(du -sh "$DMG" | cut -f1))"
fi
touch "$APP"   # nudge Finder/LaunchServices to refresh the icon
echo "✓ $APP ($(du -sh "$APP" | cut -f1))"

# GitHub caps a release asset at 2 GB. With the weights inside the bundle is ~1.7 GB — fine today,
# and the number to watch if the model is ever replaced with a larger one.
#
# Measured in whole megabytes, because `test` compares integers only: the previous version read
# `[ "${SIZE%G}" -ge 2 ]` against a du -sh string of "1.7", which is not an integer. So the guard
# never fired — and worse, `test` exits 2 on a malformed comparison, and this was the last command
# in the file, so a build that signed, notarised, stapled and passed Gatekeeper still reported
# failure to anything reading the exit code.
MEGABYTES="$(du -sm "$APP" | cut -f1)"
if [ "$MEGABYTES" -ge 2048 ]; then
  echo "  WARNING: ${MEGABYTES} MB is over GitHub's 2 GB release-asset limit — this cannot be" >&2
  echo "  attached to a release. Ship the disk image, or host the download off GitHub." >&2
fi

# Explicitly, so that a warning check can never again decide the exit status of the whole build.
exit 0
