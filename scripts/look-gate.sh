#!/bin/sh
# The release gate on what a look does to real photographs — docs/RELEASING.md, "Cutting a release".
#
#   scripts/look-gate.sh            audit the frames and compare with the accepted baseline
#   scripts/look-gate.sh --accept   make this run the new baseline (after looking at why it changed)
#
# The frames are YOURS and stay out of the repository: a TSV of `<photo path>[TAB<perception.json>]`
# at $KELVIN_GATE_DIR/frames.tsv (default ~/.kelvin/look-gate). Pick frames that have gone wrong
# before and a spread of the rest; `look-audit --help` explains the columns. iCloud-evicted frames are
# skipped, never downloaded, and the gate says which went missing.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${KELVIN_GATE_DIR:-$HOME/.kelvin/look-gate}"
LIST="$DIR/frames.tsv"
[ -f "$LIST" ] || { echo "look-gate: no frame list at $LIST — see the header of this script" >&2; exit 2; }
BUILD="${BUILD_PATH:-${TMPDIR:-/tmp}/kelvin-build}"
swift build -c release --scratch-path "$BUILD" --product kelvin-cli --package-path "$ROOT" >/dev/null
CLI="$BUILD/release/kelvin-cli"
NOW="$DIR/current.jsonl"
rm -f "$NOW"
"$CLI" look-audit --list "$LIST" --out "$NOW" | grep -E "^look-audit:|✗" || true
if [ "${1:-}" = "--accept" ] || [ ! -f "$DIR/baseline.jsonl" ]; then
  cp "$NOW" "$DIR/baseline.jsonl"
  echo "look-gate: baseline recorded at $DIR/baseline.jsonl"
  exit 0
fi
"$CLI" look-gate --baseline "$DIR/baseline.jsonl" --current "$NOW"
