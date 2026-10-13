#!/bin/bash
# Scratch tests for the learning side: correction → rule(s) → gate
# (RuleLearning), and spelled-letter detection on real Parakeet output
# (RedictationLearner). Offline, no key, no app.
# Usage: scripts/rule-learning-tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
swiftc -parse-as-library \
  Airboard/SoundCode.swift Airboard/SpellingRule.swift Airboard/CandidateFinder.swift \
  Airboard/EditDiff.swift Airboard/CorrectionWatchPolicy.swift Airboard/RedictationLearner.swift \
  Airboard/RuleLearning.swift \
  scripts/rule-learning-tests/main.swift -o "$OUT/rule-learning-tests" 2>&1 | grep -v warning || true
"$OUT/rule-learning-tests"
