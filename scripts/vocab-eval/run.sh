#!/bin/bash
# Decision eval gate for vocabulary learning (synthetic cases only).
# Usage: OPENROUTER_API_KEY=sk-or-… scripts/vocab-eval/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
swiftc -parse-as-library \
  Airboard/SoundCode.swift Airboard/SpellingRule.swift Airboard/CandidateFinder.swift \
  Airboard/DecisionTypes.swift Airboard/DecisionClient.swift Airboard/VocabularyResolver.swift \
  scripts/vocab-eval/main.swift -o "$OUT/vocab-eval"
"$OUT/vocab-eval" scripts/vocab-eval/cases.json
