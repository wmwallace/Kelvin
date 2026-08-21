#!/bin/sh
# Ratchet on `Task.detached` in the app. Not a ban — a detached task that only *awaits* lanes is
# fine — but every one of the thirty that used to block a cooperative thread looked reasonable on
# its own, and the sum of them was the app sitting in the Dock for three hours unable to quit
# (docs/DECISIONS.md, D21). So the count may fall and may not rise. To add one legitimately, move
# the blocking call into an `Offload` lane, then lower nothing; to add one that really must exist,
# raise BASELINE in the same commit and say why in its message.
set -eu
cd "$(dirname "$0")/.."
BASELINE=12
count=$(grep -rc "Task.detached" Integrations/KelvinPerceptionMLX/Sources/KelvinApp --include='*.swift' | awk -F: '{s+=$2} END {print s+0}')
if [ "$count" -gt "$BASELINE" ]; then
  echo "check-detached: $count occurrences of Task.detached in KelvinApp, baseline is $BASELINE." >&2
  echo "Blocking work belongs on an Offload lane (Sources/KelvinApp/Offload.swift), not a detached task. See D21." >&2
  grep -rn "Task.detached" Integrations/KelvinPerceptionMLX/Sources/KelvinApp --include='*.swift' >&2
  exit 1
fi
echo "check-detached: $count/$BASELINE"
