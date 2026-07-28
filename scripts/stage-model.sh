#!/bin/bash
#
# Stage the perception model for bundling inside the app.
#
# WHY THIS EXISTS
#
# The app used to fetch ~1.6 GB of weights from huggingface.co on first use: unannounced, from an app
# whose first promise is "no cloud, no account, no upload", and failing silently to a conservative
# read when the network was not there. Shipping the weights inside the bundle removes the request
# entirely rather than making it quieter (D-model-4).
#
# WHAT IT REFUSES TO DO
#
# Stage weights without their licence. Apache-2.0 permits redistribution in object form — which is
# what bundling is — but only with the licence text and any NOTICE included. *Using* weights and
# *shipping* them are different bars, and the local Hugging Face cache does not contain the licence
# files because MLX only downloads what it needs to run. So this script will not produce a staging
# directory it cannot see the terms for; it prints the two URLs to fetch and stops.
#
# USAGE
#   scripts/stage-model.sh                       # from the default model's HF cache
#   scripts/stage-model.sh <snapshot-directory>  # from somewhere else
#
# The staged directory is gitignored. 1.6 GB does not belong in a git repository; it belongs in the
# release bundle, assembled at package time.

set -euo pipefail

MODEL_REPO="${KELVIN_MODEL:-mlx-community/Qwen3.5-2B-MLX-4bit}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$ROOT/Vendor/PerceptionModel"

# The source snapshot: given explicitly, or the newest snapshot in the HF cache.
if [[ $# -ge 1 ]]; then
    SOURCE="$1"
else
    HUB="${HF_HOME:-$HOME/.cache/huggingface}/hub"
    CACHE_DIR="$HUB/models--$(echo "$MODEL_REPO" | sed 's|/|--|')"
    if [[ ! -d "$CACHE_DIR/snapshots" ]]; then
        echo "error: no local cache for $MODEL_REPO at $CACHE_DIR" >&2
        echo "       run the app or kelvin-perceive once to populate it, or pass a directory." >&2
        exit 1
    fi
    SOURCE="$(find "$CACHE_DIR/snapshots" -mindepth 1 -maxdepth 1 -type d | head -1)"
fi

if [[ ! -f "$SOURCE/config.json" ]]; then
    echo "error: $SOURCE does not look like a model directory (no config.json)" >&2
    exit 1
fi

# THE LICENCE GATE. Checked before anything is copied, so a failed run leaves no half-staged bundle
# that a later build might pick up and ship.
missing=0
for required in LICENSE; do
    if [[ ! -f "$SOURCE/$required" ]]; then
        echo "error: $required is not present in $SOURCE" >&2
        missing=1
    fi
done
if [[ $missing -eq 1 ]]; then
    cat >&2 <<EOF

Bundling the weights means redistributing them, and Apache-2.0 §4 requires the licence text to
travel with them. MLX does not download it, so it has to be fetched once and kept beside the weights:

  curl -Lo "$SOURCE/LICENSE" \\
    "https://huggingface.co/$MODEL_REPO/resolve/main/LICENSE"

  # And the upstream base model's NOTICE, if it publishes one:
  curl -fLo "$SOURCE/NOTICE" \\
    "https://huggingface.co/Qwen/Qwen3.5-2B/resolve/main/NOTICE" || true

Confirm while you are there that the repo card still says Apache-2.0. The licence recorded in
docs/DECISIONS.md (D-model-3) was read from the card during a model comparison, not from a licence
file we hold — and one Qwen model in that family is research-only, which is exactly the mistake that
entry exists to document.
EOF
    exit 1
fi

echo "Staging $MODEL_REPO"
echo "  from $SOURCE"
echo "  to   $STAGE"

rm -rf "$STAGE"
mkdir -p "$STAGE"

# Follow symlinks: the HF cache stores blobs and links to them, and a bundle full of links pointing
# into ~/.cache is a bundle that works on this machine only.
for file in "$SOURCE"/*; do
    cp -L "$file" "$STAGE/"
done

# READABLE BY EVERY USER OF THE MACHINE, not just whoever ran this. Hugging Face writes its cache
# blobs 0600, `cp` carries that through, and a bundle assembled from it ships weights only the
# installing account can open — so a second person on a family Mac launches the app from
# /Applications and it fails on the first photo with no obvious cause. Found by Sparkle's
# BinaryDelta, which warns about irregular permissions inside a bundle; v0.1.0 shipped this way.
# Directories need +x to be traversable, hence a+rX rather than a+r.
chmod -R a+rX "$STAGE"

echo
echo "Staged $(du -sh "$STAGE" | cut -f1):"
ls -1 "$STAGE" | sed 's/^/  /'
echo
echo "The app loads this from Contents/Resources/PerceptionModel at launch, or from"
echo "KELVIN_MODEL_PATH=$STAGE when running via 'swift run'."
