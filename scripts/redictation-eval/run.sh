#!/bin/bash
# Offline eval for learning from Airboard's own transcripts (spelled
# letters, follow-up corrections, re-dictation). Synthetic traces only.
# Usage: scripts/redictation-eval/run.sh
#        OPENROUTER_API_KEY=sk-or-… scripts/redictation-eval/run.sh   (adds the decision-model gate)
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
swiftc -parse-as-library \
  Airboard/SoundCode.swift Airboard/SpellingRule.swift Airboard/CandidateFinder.swift \
  Airboard/DecisionTypes.swift Airboard/DecisionClient.swift Airboard/VocabularyResolver.swift \
  Airboard/RedictationLearner.swift \
  scripts/redictation-eval/main.swift -o "$OUT/redictation-eval"
"$OUT/redictation-eval" scripts/redictation-eval/traces.json
