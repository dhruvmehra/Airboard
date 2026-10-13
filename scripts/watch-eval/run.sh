#!/bin/bash
# Correction-watcher timeline simulator + policy tests (offline, no key).
# Usage: scripts/watch-eval/run.sh [-v]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
swiftc -O \
  Airboard/SoundCode.swift Airboard/EditDiff.swift Airboard/CorrectionWatchPolicy.swift \
  Airboard/SpellingRule.swift Airboard/CandidateFinder.swift Airboard/RuleLearning.swift \
  scripts/watch-eval/main.swift -o "$OUT/watch-eval"
"$OUT/watch-eval" "$@"
