#!/bin/bash
# Apply-side tests for learned spellings (no key / timeout / hands-free and
# simulated decision-engine answers), real Parakeet outputs, timing.
#   scripts/apply-tests/run.sh            before (BASE rev) vs current working tree; exits 1 on a failed assertion
#   BASE=<rev> scripts/apply-tests/run.sh compare against another revision
#   scripts/apply-tests/run.sh -v         also list corpus negatives changed / wrong insertions
# Offline; reads scripts/name-eval/corpus.json (if present) and parakeet.tsv.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(cd "$HERE/../.." && pwd)"
BASE="${BASE:-05e883d}"
FILES="SoundCode SpellingRule CandidateFinder VocabularyResolver"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CORPUS="$W/scripts/name-eval/corpus.json"
ARGS=(--parakeet "$HERE/parakeet.tsv")
[ -f "$CORPUS" ] && ARGS+=(--corpus "$CORPUS")

mkdir -p "$TMP/before" "$TMP/current"
for f in $FILES; do
  git -C "$W" show "$BASE:Airboard/$f.swift" > "$TMP/before/$f.swift"
  cp "$W/Airboard/$f.swift" "$TMP/current/"
done
swiftc -O "$TMP"/before/*.swift "$HERE/main.swift" -o "$TMP/before/t" || { echo "before: compile failed"; exit 2; }
swiftc -O -D NEW "$TMP"/current/*.swift "$HERE/main.swift" -o "$TMP/current/t" || { echo "current: compile failed"; exit 2; }
"$TMP/before/t" "${ARGS[@]}" --label "before $BASE" | grep -v '^   \[' 
echo
"$TMP/current/t" "${ARGS[@]}" --label current --assert "$@"
