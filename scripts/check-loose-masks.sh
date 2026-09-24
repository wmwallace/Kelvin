#!/bin/sh
# Ratchet on copying `LocalMasks` measurements into the engine field by field. Every caller that
# did it by hand got the set wrong eventually: D20's face-lift cap reached the eval harness and not
# the app, because the app copied three of the four fields and the fourth defaulted to false.
# Production code hands the engine `masks: measured.summary` (Engine/MeasuredCandidates.swift).
# `lightsCoverage` (engine 0.7.3) is in the pattern for the same reason: a fifth field is a fifth
# chance to forget one.
# The count may fall and may not rise; the ones left are `RecipeEngine.recipe()`, the single-recipe
# path the app never calls, which is scheduled for deletion.
set -eu
cd "$(dirname "$0")/.."
BASELINE=7
hits=$(grep -rnE --include='*.swift' '\b(subjectLuma|skyLuma|subjectOrigin|subjectLumaIsSkin|lightsCoverage):' \
         Sources Integrations/KelvinPerceptionMLX/Sources \
       | grep -v '/.build/' \
       | grep -v -E '^Sources/KelvinCore/(Engine/|Render/LocalMasks\.swift)' \
       | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*//' || true)
count=$(printf '%s' "$hits" | grep -c . || true)
if [ "$count" -gt "$BASELINE" ]; then
  echo "check-loose-masks: $count loose mask arguments outside the engine, baseline is $BASELINE." >&2
  echo "Pass the measurement whole — RecipeEngine.candidates(…, masks: measured.summary, …)." >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "check-loose-masks: $count/$BASELINE"
