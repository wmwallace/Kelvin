#!/usr/bin/env bash
# Make sure SwiftPM's Sparkle artifact is actually there before a build depends on it.
#
#   scripts/sparkle-guard.sh [scratch-path ...]
#
# WHY THIS EXISTS. Twice in one evening — once mid-release — a build died on:
#
#   error: There is no Info.plist found at '…/artifacts/sparkle/Sparkle/Sparkle.xcframework/Info.plist'
#
# SwiftPM had left the artifact directory present but EMPTY, and it does not notice or re-fetch: the
# directory exists, so as far as resolution is concerned the artifact is installed. Zero bytes where
# 26 MB should be. This is the same unreliability that made `Package.swift` pin Sparkle to an exact
# version — the binary-artifact downloader in this environment cannot be relied on, and a re-resolve
# is as likely to hang as to fix it.
#
# Documenting it was not enough. A failure that costs a release build is worth a guard, not a
# paragraph, so this runs before the builds that need it and repairs the directory in place.
#
# WHERE THE GOOD COPY COMES FROM, in order:
#   1. Any other scratch path on this machine that still has a healthy artifact.
#   2. A backup kept outside every scratch directory, refreshed automatically whenever a healthy
#      artifact is seen. Scratch paths get wiped; this one does not.
# The artifact is not vendored into the repository on purpose: 26 MB of binary in every clone, for a
# problem that belongs to one machine's SwiftPM cache, is the wrong trade.
set -euo pipefail

BACKUP="${KELVIN_SPARKLE_BACKUP:-$HOME/Library/Caches/Kelvin/sparkle-artifact}"

# The scratch paths this project builds into. Given ones win; otherwise check the usual suspects,
# which is what `make` and `scripts/package-app.sh` use.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ $# -gt 0 ]; then
  SCRATCHES=("$@")
else
  SCRATCHES=(
    "${TMPDIR:-/tmp}kelvin-build"
    "${TMPDIR:-/tmp}kelvin-app-build"
    "${TMPDIR:-/tmp}kelvin-package-build"
    "$ROOT/Integrations/KelvinPerceptionMLX/.build"
  )
fi

# Healthy means the two things builds actually reach for: the framework's plist, and the command-line
# tools the release process uses. Checking only the directory's existence is precisely the mistake
# SwiftPM makes.
healthy() {
  [ -f "$1/Sparkle/Sparkle.xcframework/Info.plist" ] && [ -x "$1/Sparkle/bin/sign_update" ]
}

donor=""
broken=()
for scratch in "${SCRATCHES[@]}"; do
  artifact="$scratch/artifacts/sparkle"
  # A scratch path that has never been built into is not broken, it is absent. Leave it alone —
  # SwiftPM will populate it, and if that fails this script runs again next time.
  [ -d "$scratch" ] || continue
  if healthy "$artifact"; then
    donor="${donor:-$artifact}"
  elif [ -d "$artifact" ]; then
    broken+=("$artifact")
  fi
done

# Keep the off-scratch backup current whenever a good copy is in front of us.
if [ -n "$donor" ]; then
  if ! healthy "$BACKUP"; then
    mkdir -p "$(dirname "$BACKUP")"
    rm -rf "$BACKUP.tmp"
    # -c asks for a copy-on-write clone where the filesystem supports it, so refreshing the backup
    # costs no time and no disk until something changes.
    cp -Rc "$donor" "$BACKUP.tmp" 2>/dev/null || cp -R "$donor" "$BACKUP.tmp"
    rm -rf "$BACKUP"; mv "$BACKUP.tmp" "$BACKUP"
    echo "sparkle-guard: backed up a healthy artifact to $BACKUP"
  fi
fi

[ ${#broken[@]} -eq 0 ] && exit 0

source="$donor"
[ -n "$source" ] || { healthy "$BACKUP" && source="$BACKUP"; }
if [ -z "$source" ]; then
  echo "sparkle-guard: the Sparkle artifact is empty and there is no healthy copy to restore from." >&2
  echo "  Broken: ${broken[*]}" >&2
  echo "  Fix it once by hand — 'swift package resolve --package-path Integrations/KelvinPerceptionMLX'" >&2
  echo "  — and this will keep a backup from then on. If resolve hangs, that is the known artifact" >&2
  echo "  downloader problem; see docs/RELEASING.md." >&2
  exit 1
fi

for artifact in "${broken[@]}"; do
  echo "sparkle-guard: repairing empty artifact at $artifact"
  rm -rf "$artifact"
  cp -Rc "$source" "$artifact" 2>/dev/null || cp -R "$source" "$artifact"
done
